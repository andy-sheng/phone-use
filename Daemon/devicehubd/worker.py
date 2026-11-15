"""Per-device worker: holds one tunnel and exposes the device's services on loopback ports.

pymobiledevice3's userspace TCP/IP stack is a process-wide singleton, so every device gets
its own worker process. The supervisor talks to it over stdin/stdout with the JSON framing
in `protocol`; closing stdin shuts the worker down.
"""

import argparse
import asyncio
import contextlib
import logging
import os
import socket
import sys
from typing import Any, Optional

from packaging.version import Version
from pymobiledevice3.exceptions import AlreadyMountedError
from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService
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
        self._rsd = await self._tunnel.open()
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
    logging.basicConfig(level=logging.INFO, format=f"[worker {args.udid[-6:]}] %(levelname)s %(name)s: %(message)s")

    # Library code may print; keep the protocol stream on a private copy of stdout.
    out = os.fdopen(os.dup(sys.stdout.fileno()), "wb", buffering=0)
    os.dup2(sys.stderr.fileno(), sys.stdout.fileno())
    # pymobiledevice3 may leave background tasks around; skip asyncio.run teardown, which would
    # wait for them, because the supervisor only needs us gone.
    code = asyncio.Runner().run(run(args.udid, args.connection, out))
    os._exit(code)


if __name__ == "__main__":
    main()
