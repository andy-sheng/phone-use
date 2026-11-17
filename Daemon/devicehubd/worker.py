"""Per-device worker: holds one tunnel and exposes the device's services on loopback ports.

pymobiledevice3's userspace TCP/IP stack is a process-wide singleton, so every device gets
its own worker process. The supervisor talks to it over stdin/stdout with the JSON framing
in `protocol`; closing stdin shuts the worker down.
"""

import argparse
import asyncio
import contextlib
import json
import logging
import os
import socket
import sys
import time
from typing import Any, Optional

from packaging.version import Version
from pymobiledevice3.exceptions import AlreadyMountedError
from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService
from pymobiledevice3.services.accessibilityaudit import AccessibilityAudit
from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation
from pymobiledevice3.services.mobile_image_mounter import auto_mount

from devicehubd import protocol
from devicehubd.lifetime import WORKER_EXIT_DEADLINE, exit_after
from devicehubd.protocol import RpcError
from devicehubd.transports import Tunnel, make_tunnel

logger = logging.getLogger("devicehubd.worker")

MIRROR_MIN_VERSION = Version("27.0")
# Served by dtuhidd from the Developer Disk Image; its absence means the image is not mounted.
DDI_MARKER_SERVICE = "com.apple.coredevice.hid.universalhidservice"
MIRROR_START_TIMEOUT = 40.0
LOCATION_START_TIMEOUT = 20.0
# Settings the accessibility audit service accepts, with the value type each one takes.
ACCESSIBILITY_SETTINGS = {
    "INCREASE_CONTRAST": bool,
    "REDUCE_MOTION": bool,
    "REDUCE_TRANSPARENCY": bool,
    "BUTTON_SHAPES": bool,
    "GRAYSCALE": bool,
    "INVERT_COLORS": bool,
    "ON_OFF_LABELS": bool,
    "DIFFERENTIATE_WITHOUT_COLOR": bool,
    "DYNAMIC_TYPE": float,
}


def accessibility_value(name: Any, raw: Any) -> tuple[str, Any]:
    """Validates a setting update from a client, whose value arrives JSON-encoded."""
    kind = ACCESSIBILITY_SETTINGS.get(name)
    if kind is None:
        raise RpcError("invalidParams", f"Unknown accessibility setting {name}")
    try:
        value = json.loads(raw) if isinstance(raw, str) else raw
    except ValueError:
        raise RpcError("invalidParams", f"Invalid value for {name}") from None
    if kind is bool and isinstance(value, bool):
        return name, value
    if kind is float and isinstance(value, (int, float)) and not isinstance(value, bool) and 0 <= value <= 1:
        return name, float(value)
    raise RpcError("invalidParams", f"Invalid value for {name}")


def coordinate(params: dict[str, Any]) -> tuple[float, float]:
    try:
        latitude, longitude = float(params["latitude"]), float(params["longitude"])
    except (KeyError, TypeError, ValueError):
        raise RpcError("invalidParams", "latitude and longitude are required") from None
    if not (-90 <= latitude <= 90 and -180 <= longitude <= 180):
        raise RpcError("invalidParams", "Coordinates are out of range")
    return latitude, longitude


class Worker:
    def __init__(self, udid: str, connection: str, out: Any) -> None:
        self.udid = udid
        self.connection = connection
        self._out = out
        self._out_lock = asyncio.Lock()
        self._tunnel: Tunnel = make_tunnel(connection, udid)
        self._rsd: Optional[RemoteServiceDiscoveryService] = None
        self._forwards: dict[str, asyncio.AbstractServer] = {}
        self._mirror_task: Optional[asyncio.Task[None]] = None
        self._mirror_port: Optional[int] = None
        self._mirror_lock = asyncio.Lock()
        self._location_task: Optional[asyncio.Task[None]] = None
        self._location_lock = asyncio.Lock()
        self._audit: Optional[AccessibilityAudit] = None
        self._audit_lock = asyncio.Lock()

    async def emit(self, message: dict[str, Any]) -> None:
        async with self._out_lock:
            self._out.write(protocol.encode(message))
            self._out.flush()

    @property
    def rsd(self) -> RemoteServiceDiscoveryService:
        if self._rsd is None:
            raise RpcError("disconnected", "The device tunnel is closed")
        return self._rsd

    def services(self) -> list[str]:
        return sorted((self.rsd.peer_info or {}).get("Services", {}).keys())

    async def start(self) -> None:
        started = time.monotonic()
        logger.info("tunnel.open.begin connection=%s", self.connection)
        self._rsd = await self._tunnel.open()
        logger.info("tunnel.open.ok connection=%s elapsed_ms=%.0f os=%s", self.connection,
                    (time.monotonic() - started) * 1000, self._rsd.product_version)
        if DDI_MARKER_SERVICE not in self.services():
            # iOS 27 installs the image as a cryptex, which needs the tunnel; older systems were
            # already mounted over lockdown by the supervisor.
            with contextlib.suppress(AlreadyMountedError):
                await auto_mount(self._rsd)
            self._rsd = await self._rediscover()
        if DDI_MARKER_SERVICE not in self.services():
            raise RpcError("developerImageMissing", "The Developer Disk Image services are not available")

    async def _rediscover(self) -> RemoteServiceDiscoveryService:
        """Services published by a freshly mounted image only show up in a new RSD handshake."""
        old = self.rsd
        rsd = RemoteServiceDiscoveryService(old.service.address, open_connection=old.open_connection)
        await rsd.connect()
        return rsd

    async def forward(self, service: str) -> int:
        """Listen on a loopback port that relays each connection to ``service`` on the device."""
        server = self._forwards.get(service)
        if server is None:
            device_port = self.rsd.get_service_port(service)
            server = await asyncio.start_server(
                lambda reader, writer: self._relay(reader, writer, device_port), "127.0.0.1", 0
            )
            self._forwards[service] = server
        return server.sockets[0].getsockname()[1]

    async def _relay(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter, device_port: int) -> None:
        try:
            device_reader, device_writer = await self.rsd.open_connection(self.rsd.service.address[0], device_port)
        except Exception as e:
            logger.warning("relay to port %d failed: %r", device_port, e)
            writer.close()
            return

        async def pump(source: asyncio.StreamReader, sink: asyncio.StreamWriter) -> None:
            try:
                while chunk := await source.read(65536):
                    sink.write(chunk)
                    await sink.drain()
            except (ConnectionError, OSError, asyncio.IncompleteReadError):
                pass
            finally:
                with contextlib.suppress(Exception):
                    sink.close()

        await asyncio.gather(pump(reader, device_writer), pump(device_reader, writer))

    async def start_mirror(self) -> int:
        """Serve the screen as length-prefixed HEVC access units at ``/stream.bin``.

        On iOS 27 an active media stream is also what authenticates host HID input, so this is
        started before touches as well.
        """
        if Version(self.rsd.product_version) < MIRROR_MIN_VERSION:
            raise RpcError("unsupported", f"Screen mirroring needs iOS 27; this device runs {self.rsd.product_version}")
        async with self._mirror_lock:
            if self._mirror_task is not None and not self._mirror_task.done() and self._mirror_port:
                return self._mirror_port
            from pymobiledevice3.remote.core_device.screen_stream import ScreenStreamServer

            port = _free_port()
            server = ScreenStreamServer(self.rsd, bind="127.0.0.1", http_port=port, audio_default_on=False)
            self._mirror_task = asyncio.create_task(server.serve())
            loop = asyncio.get_running_loop()
            deadline = loop.time() + MIRROR_START_TIMEOUT
            while loop.time() < deadline:
                if self._mirror_task.done():
                    error = self._mirror_task.exception()
                    raise RpcError("mirrorFailed", f"Screen mirroring failed to start: {error}")
                with contextlib.suppress(OSError):
                    _, writer = await asyncio.open_connection("127.0.0.1", port)
                    writer.close()
                    self._mirror_port = port
                    return port
                await asyncio.sleep(0.3)
            self._mirror_task.cancel()
            raise RpcError("timeout", "Screen mirroring did not start in time")

    async def stop_mirror(self) -> None:
        async with self._mirror_lock:
            task, self._mirror_task, self._mirror_port = self._mirror_task, None, None
        if task is not None:
            task.cancel()
            with contextlib.suppress(BaseException):
                await task

    async def accessibility_settings(self) -> dict[str, Any]:
        async with self._audit_lock:
            return await self._with_audit(lambda audit: self._read_settings(audit))

    async def set_accessibility_setting(self, name: str, value: Any) -> dict[str, Any]:
        async def update(audit: AccessibilityAudit) -> dict[str, Any]:
            await audit.set_setting(name, value)
            # The update has no reply; this read makes sure the channel delivered it, but may
            # still report the previous value.
            return await self._read_settings(audit)

        async with self._audit_lock:
            return await self._with_audit(update)

    @staticmethod
    async def _read_settings(audit: AccessibilityAudit) -> dict[str, Any]:
        return {setting.key: setting.value for setting in await audit.settings()}

    async def _with_audit(self, operation: Any) -> Any:
        """The device keeps settings changed over the audit channel only while it stays open,
        so one channel is held for the worker's lifetime; closing it restores the device's own."""
        if self._audit is None:
            audit = AccessibilityAudit(self.rsd)
            await audit.__aenter__()
            self._audit = audit
        try:
            return await operation(self._audit)
        except Exception:
            await self._close_audit()
            raise

    async def _close_audit(self) -> None:
        audit, self._audit = self._audit, None
        if audit is not None:
            with contextlib.suppress(Exception):
                await asyncio.wait_for(audit.__aexit__(None, None, None), timeout=3)

    async def simulate_location(self, latitude: float, longitude: float) -> None:
        """The device keeps a simulated location only while its DVT channel stays open."""
        async with self._location_lock:
            await self._stop_location()
            ready: asyncio.Future[None] = asyncio.get_running_loop().create_future()
            task = asyncio.create_task(self._hold_location(latitude, longitude, ready))
            self._location_task = task
            try:
                await asyncio.wait_for(asyncio.shield(ready), LOCATION_START_TIMEOUT)
            except BaseException:
                await self._stop_location()
                raise

    async def _hold_location(self, latitude: float, longitude: float, ready: "asyncio.Future[None]") -> None:
        try:
            async with DvtProvider(self.rsd) as dvt, LocationSimulation(dvt) as simulation:
                await simulation.set(latitude, longitude)
                ready.set_result(None)
                await asyncio.Event().wait()
        except asyncio.CancelledError:
            raise
        except Exception as e:
            if not ready.done():
                ready.set_exception(RpcError("locationFailed", str(e)))
            else:
                logger.warning("location simulation for %s ended: %s", self.udid, e)

    async def clear_location(self) -> None:
        async with self._location_lock:
            await self._stop_location()
            async with DvtProvider(self.rsd) as dvt, LocationSimulation(dvt) as simulation:
                await simulation.clear()

    async def _stop_location(self) -> None:
        task, self._location_task = self._location_task, None
        if task is not None:
            task.cancel()
            with contextlib.suppress(BaseException):
                await task

    async def handle(self, message: dict[str, Any]) -> None:
        request_id = message.get("id")
        method = message.get("method")
        params = message.get("params") or {}
        try:
            if method == "forward":
                result: Any = {"port": await self.forward(params["service"])}
            elif method == "startMirror":
                result = {"port": await self.start_mirror(), "path": "/stream.bin"}
            elif method == "stopMirror":
                await self.stop_mirror()
                result = {}
            elif method == "accessibilitySettings":
                result = {"settings": await self.accessibility_settings()}
            elif method == "setAccessibilitySetting":
                name, value = accessibility_value(params.get("name"), params.get("value"))
                result = {"settings": await self.set_accessibility_setting(name, value)}
            elif method == "simulateLocation":
                await self.simulate_location(*coordinate(params))
                result = {}
            elif method == "clearLocation":
                await self.clear_location()
                result = {}
            else:
                raise RpcError("unknownMethod", f"Unknown worker method {method}")
            await self.emit({"id": request_id, "result": result})
        except RpcError as e:
            await self.emit({"id": request_id, "error": e.to_json()})
        except Exception as e:
            logger.exception("worker request %s failed", method)
            await self.emit({"id": request_id, "error": {"code": "internal", "message": str(e)}})

    async def watch_tunnel(self) -> None:
        while self._tunnel.rsd is not None:
            await asyncio.sleep(1)

    async def close(self) -> None:
        await self.stop_mirror()
        await self._stop_location()
        await self._close_audit()
        for server in self._forwards.values():
            server.close()
        with contextlib.suppress(Exception):
            await asyncio.wait_for(self._tunnel.close(), timeout=3)


def _free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


async def run(udid: str, connection: str, out: Any) -> int:
    worker = Worker(udid, connection, out)
    try:
        await worker.start()
    except RpcError as e:
        logger.warning("worker.start.failed connection=%s code=%s error=%s", connection, e.code, e)
        await worker.emit({"event": "failed", "error": e.to_json()})
        return 1
    except Exception as e:
        logger.exception("worker for %s failed to start", udid)
        await worker.emit({"event": "failed", "error": {"code": "tunnelFailed", "message": str(e)}})
        return 1

    await worker.emit({
        "event": "ready",
        "productVersion": worker.rsd.product_version,
        "services": worker.services(),
    })

    loop = asyncio.get_running_loop()
    reader = asyncio.StreamReader()
    await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), sys.stdin)

    async def commands() -> None:
        while line := await reader.readline():
            with contextlib.suppress(ValueError):
                asyncio.create_task(worker.handle(protocol.decode(line)))

    command_task = asyncio.create_task(commands())
    tunnel_task = asyncio.create_task(worker.watch_tunnel())
    done, _ = await asyncio.wait({command_task, tunnel_task}, return_when=asyncio.FIRST_COMPLETED)
    # The supervisor escalates to SIGKILL on its own; this covers a supervisor that is already gone.
    exit_after(WORKER_EXIT_DEADLINE)
    if tunnel_task in done:
        logger.warning("tunnel.closed connection=%s", connection)
        await worker.emit({"event": "closed", "error": {"code": "disconnected", "message": "The device tunnel closed"}})
    command_task.cancel()
    tunnel_task.cancel()
    await worker.close()
    return 0


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--udid", required=True)
    parser.add_argument("--connection", default="usb")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format=f"%(asctime)s [worker {args.udid[-6:]} pid=%(process)d] %(levelname)s %(name)s: %(message)s")

    # Library code may print; keep the protocol stream on a private copy of stdout.
    out = os.fdopen(os.dup(sys.stdout.fileno()), "wb", buffering=0)
    os.dup2(sys.stderr.fileno(), sys.stdout.fileno())
    # pymobiledevice3 may leave background tasks around; skip asyncio.run teardown, which would
    # wait for them, because the supervisor only needs us gone.
    code = asyncio.Runner().run(run(args.udid, args.connection, out))
    os._exit(code)


if __name__ == "__main__":
    main()
