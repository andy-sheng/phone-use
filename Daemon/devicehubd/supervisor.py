"""Supervisor: tracks attached devices and their readiness, and runs one worker per open device.

Clients (the app, the MCP server, the CLI) connect to a Unix socket and speak the framing in
`protocol`. Methods:

* ``hello``, ``listDevices``, ``subscribe`` (then ``devicesChanged`` notifications)
* ``pair``, ``revealDeveloperMode``, ``mountDeveloperImage`` -- onboarding steps
* ``openDevice`` -> ``{udid, productVersion, services}``; ``closeDevice``
* ``openService`` -> ``{port}``: a loopback port relaying to that device service
* ``startMirror`` -> ``{port, path}`` (iOS 27+); ``stopMirror``
"""

import asyncio
import contextlib
import logging
import os
import sys
from dataclasses import dataclass, field
from typing import Any, Optional

from packaging.version import Version
from pymobiledevice3.exceptions import AlreadyMountedError
from pymobiledevice3.services.amfi import AmfiService
from pymobiledevice3.services.mobile_image_mounter import (
    MobileImageMounterService,
    auto_mount,
    image_type_for_device,
)

from devicehubd import VERSION, protocol
from devicehubd.protocol import RpcError
from devicehubd.transports import DISCOVERIES, discovery_for

logger = logging.getLogger("devicehubd")

POLL_INTERVAL = 1.5
REPROBE_INTERVAL = 5.0
WORKER_START_TIMEOUT = 90.0
TUNNEL_MOUNTS_VERSION = Version("27.0")


@dataclass
class DeviceRecord:
    udid: str
    connection: str
    attached: bool = True
    name: Optional[str] = None
    product_type: Optional[str] = None
    product_version: Optional[str] = None
    build_version: Optional[str] = None
    paired: Optional[bool] = None
    developer_mode: Optional[bool] = None
    developer_image: Optional[bool] = None
    session: str = "closed"
    error: Optional[str] = None
    probed_at: float = 0.0

    @property
    def image_needs_tunnel(self) -> bool:
        return self.product_version is not None and Version(self.product_version) >= TUNNEL_MOUNTS_VERSION

    @property
    def state(self) -> str:
        if not self.attached:
            return "disconnected"
        if self.paired is None:
            return "probing"
        if not self.paired:
            return "untrusted"
        if not self.developer_mode:
            return "developerModeOff"
        if not self.developer_image and not self.image_needs_tunnel:
            return "developerImageMissing"
        return "ready"

    def to_json(self) -> dict[str, Any]:
        return {
            "udid": self.udid,
            "connection": self.connection,
            "name": self.name or self.product_type or self.udid,
            "productType": self.product_type,
            "productVersion": self.product_version,
            "buildVersion": self.build_version,
            "state": self.state,
            "paired": self.paired,
            "developerMode": self.developer_mode,
            "developerImage": self.developer_image,
            "session": self.session,
            "error": self.error,
        }


@dataclass
class WorkerHandle:
    process: asyncio.subprocess.Process
    ready: asyncio.Future[dict[str, Any]]
    pending: dict[int, asyncio.Future[Any]] = field(default_factory=dict)
    next_id: int = 1
    info: dict[str, Any] = field(default_factory=dict)

    async def call(self, method: str, params: dict[str, Any], timeout: float = 60.0) -> Any:
        if self.process.returncode is not None or self.process.stdin is None:
            raise RpcError("disconnected", "The device worker has exited")
        request_id = self.next_id
        self.next_id += 1
        future: asyncio.Future[Any] = asyncio.get_running_loop().create_future()
        self.pending[request_id] = future
        self.process.stdin.write(protocol.encode({"id": request_id, "method": method, "params": params}))
        await self.process.stdin.drain()
        try:
            return await asyncio.wait_for(future, timeout)
        finally:
            self.pending.pop(request_id, None)

    def stop(self) -> None:
        if self.process.returncode is None and self.process.stdin is not None:
            self.process.stdin.close()


class Supervisor:
    def __init__(self) -> None:
        self.records: dict[str, DeviceRecord] = {}
        self.workers: dict[str, WorkerHandle] = {}
        self.subscribers: set[asyncio.StreamWriter] = set()
        self._device_locks: dict[str, asyncio.Lock] = {}
        self._probing: set[str] = set()

    # MARK: Device tracking

    def _lock(self, udid: str) -> asyncio.Lock:
        return self._device_locks.setdefault(udid, asyncio.Lock())

    async def monitor(self) -> None:
        loop = asyncio.get_running_loop()
        while True:
            seen: dict[str, str] = {}
            for discovery in DISCOVERIES:
                try:
                    for attachment in await discovery.attached():
                        seen[attachment.udid] = attachment.connection
                except Exception as e:
                    logger.debug("%s discovery failed: %r", discovery.connection, e)
            changed = False
            for udid, connection in seen.items():
                record = self.records.get(udid)
                if record is None or not record.attached or record.connection != connection:
                    self.records[udid] = record = DeviceRecord(
                        udid, connection, name=record.name if record else None
                    )
                    changed = True
                if record.state != "ready" and loop.time() - record.probed_at > REPROBE_INTERVAL:
                    self._schedule_probe(udid)
            for udid, record in self.records.items():
                if record.attached and udid not in seen:
                    record.attached = False
                    record.session = "closed"
                    changed = True
                    worker = self.workers.pop(udid, None)
                    if worker is not None:
                        worker.stop()
            if changed:
                await self.broadcast()
            await asyncio.sleep(POLL_INTERVAL)

    def _schedule_probe(self, udid: str) -> None:
        if udid in self._probing:
            return
        self._probing.add(udid)

        async def run() -> None:
            try:
                await self.probe(udid)
            finally:
                self._probing.discard(udid)

        asyncio.create_task(run())

    async def probe(self, udid: str) -> None:
        record = self.records.get(udid)
        if record is None or not record.attached:
            return
        record.probed_at = asyncio.get_running_loop().time()
        before = record.to_json()
        try:
            lockdown = await discovery_for(record.connection).lockdown(udid)
        except Exception as e:
            logger.debug("probe of %s failed: %r", udid, e)
            return
        try:
            values = lockdown.all_values
            record.name = values.get("DeviceName") or record.name
            record.product_type = values.get("ProductType")
            record.product_version = values.get("ProductVersion")
            record.build_version = values.get("BuildVersion")
            record.paired = await lockdown.validate_pairing() if not lockdown.paired else True
            if record.paired:
                record.name = lockdown.all_values.get("DeviceName") or record.name
                async with MobileImageMounterService(lockdown=lockdown) as mounter:
                    record.developer_mode = bool(await mounter.query_developer_mode_status())
                    if record.developer_mode and not record.image_needs_tunnel:
                        record.developer_image = await mounter.is_image_mounted(image_type_for_device(lockdown))
            if record.state == "developerImageMissing":
                # A reboot unmounts the image; put it back without asking.
                await self._mount_over_lockdown(record, lockdown)
        except Exception as e:
            logger.warning("probe of %s incomplete: %r", udid, e)
        finally:
            with contextlib.suppress(Exception):
                await lockdown.close()
        if record.to_json() != before:
            await self.broadcast()

    async def _mount_over_lockdown(self, record: DeviceRecord, lockdown: Any) -> None:
        try:
            with contextlib.suppress(AlreadyMountedError):
                await auto_mount(lockdown)
            record.developer_image = True
            record.error = None
        except Exception as e:
            record.error = f"Mounting the Developer Disk Image failed: {e}"
            logger.warning("mount on %s failed: %r", record.udid, e)

    def _record(self, udid: Optional[str]) -> DeviceRecord:
        if not udid:
            raise RpcError("invalidParams", "Missing udid")
        record = self.records.get(udid)
        if record is None or not record.attached:
            raise RpcError("deviceNotFound", f"Device {udid} is not attached")
        return record

    async def broadcast(self) -> None:
        message = protocol.encode({"method": "devicesChanged", "params": {"devices": self.device_list()}})
        for writer in list(self.subscribers):
            try:
                writer.write(message)
                await writer.drain()
            except Exception:
                self.subscribers.discard(writer)

    def device_list(self) -> list[dict[str, Any]]:
        return [record.to_json() for record in self.records.values()]

    # MARK: Onboarding

    async def pair(self, udid: str) -> None:
        record = self._record(udid)
        lockdown = await discovery_for(record.connection).lockdown(udid)
        try:
            if not lockdown.paired:
                await lockdown.pair(timeout=120)
        except Exception as e:
            raise RpcError("pairingFailed", f"Pairing was not accepted on the device: {e}") from e
        finally:
            with contextlib.suppress(Exception):
                await lockdown.close()
        await self.probe(udid)

    async def reveal_developer_mode(self, udid: str) -> None:
        record = self._record(udid)
        lockdown = await discovery_for(record.connection).lockdown(udid)
        try:
            await AmfiService(lockdown).reveal_developer_mode_option_in_ui()
        finally:
            with contextlib.suppress(Exception):
                await lockdown.close()

    async def mount_developer_image(self, udid: str) -> None:
        record = self._record(udid)
        if record.image_needs_tunnel:
            await self.open_device(udid)
            return
        async with self._lock(udid):
            lockdown = await discovery_for(record.connection).lockdown(udid)
            try:
                await self._mount_over_lockdown(record, lockdown)
            finally:
                with contextlib.suppress(Exception):
                    await lockdown.close()
        await self.broadcast()
        if record.error:
            raise RpcError("mountFailed", record.error)

    # MARK: Workers

    async def open_device(self, udid: str) -> dict[str, Any]:
        record = self._record(udid)
        async with self._lock(udid):
            worker = self.workers.get(udid)
            if worker is None or worker.process.returncode is not None:
                if record.state == "probing" or record.state == "developerImageMissing":
                    await self.probe(udid)
                if record.state != "ready":
                    raise RpcError("notReady", f"{record.to_json()['name']} is not ready: {record.state}")
                worker = await self._spawn_worker(record)
        info = await asyncio.wait_for(asyncio.shield(worker.ready), WORKER_START_TIMEOUT)
        return {"udid": udid, "productVersion": info.get("productVersion"), "services": info.get("services", [])}

    async def _spawn_worker(self, record: DeviceRecord) -> WorkerHandle:
        process = await asyncio.create_subprocess_exec(
            sys.executable, "-m", "devicehubd.worker", "--udid", record.udid, "--connection", record.connection,
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
        )
        loop = asyncio.get_running_loop()
        worker = WorkerHandle(process, loop.create_future())
        self.workers[record.udid] = worker
        record.session = "opening"
        record.error = None
        await self.broadcast()
        asyncio.create_task(self._read_worker(record, worker))
        return worker

    async def _read_worker(self, record: DeviceRecord, worker: WorkerHandle) -> None:
        assert worker.process.stdout is not None
        failure: Optional[dict[str, Any]] = None
        while line := await worker.process.stdout.readline():
            try:
                message = protocol.decode(line)
            except ValueError:
                continue
            event = message.get("event")
            if event == "ready":
                worker.info = message
                if not worker.ready.done():
                    worker.ready.set_result(message)
                record.session = "open"
                record.developer_image = True
                await self.broadcast()
            elif event in ("failed", "closed"):
                failure = message.get("error")
            elif "id" in message:
                future = worker.pending.get(message["id"])
                if future is not None and not future.done():
                    if "error" in message:
                        error = message["error"]
                        future.set_exception(RpcError(error.get("code", "internal"), error.get("message", "")))
                    else:
                        future.set_result(message.get("result"))
        await worker.process.wait()
        error = RpcError(
            (failure or {}).get("code", "disconnected"),
            (failure or {}).get("message", "The device worker exited"),
        )
        if not worker.ready.done():
            worker.ready.set_exception(error)
        for future in worker.pending.values():
            if not future.done():
                future.set_exception(error)
        if self.workers.get(record.udid) is worker:
            del self.workers[record.udid]
            record.session = "failed" if failure and failure.get("code") != "disconnected" else "closed"
            record.error = failure.get("message") if failure else None
            await self.broadcast()

    async def _worker(self, udid: str) -> WorkerHandle:
        await self.open_device(udid)
        worker = self.workers.get(udid)
        if worker is None:
            raise RpcError("disconnected", "The device worker has exited")
        return worker

    async def close_device(self, udid: str) -> None:
        worker = self.workers.pop(udid, None)
        if worker is not None:
            worker.stop()
        record = self.records.get(udid)
        if record is not None:
            record.session = "closed"
            await self.broadcast()

    # MARK: Client connections

    async def dispatch(self, method: str, params: dict[str, Any], writer: asyncio.StreamWriter) -> Any:
        udid = params.get("udid")
        if method == "hello":
            return {"version": VERSION, "pid": os.getpid()}
        if method == "listDevices":
            return {"devices": self.device_list()}
        if method == "subscribe":
            self.subscribers.add(writer)
            return {"devices": self.device_list()}
        if method == "pair":
            await self.pair(udid)
            return {}
        if method == "revealDeveloperMode":
            await self.reveal_developer_mode(udid)
            return {}
        if method == "mountDeveloperImage":
            await self.mount_developer_image(udid)
            return {}
        if method == "openDevice":
            return await self.open_device(udid)
        if method == "openService":
            worker = await self._worker(udid)
            return await worker.call("forward", {"service": params.get("service")})
        if method == "startMirror":
            worker = await self._worker(udid)
            return await worker.call("startMirror", {}, timeout=60)
        if method == "stopMirror":
            worker = self.workers.get(udid or "")
            if worker is not None:
                await worker.call("stopMirror", {})
            return {}
        if method == "closeDevice":
            await self.close_device(udid)
            return {}
        raise RpcError("unknownMethod", f"Unknown method {method}")

    async def serve_client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        write_lock = asyncio.Lock()

        async def reply(message: dict[str, Any]) -> None:
            async with write_lock:
                writer.write(protocol.encode(message))
                await writer.drain()

        async def handle(message: dict[str, Any]) -> None:
            request_id = message.get("id")
            try:
                result = await self.dispatch(message.get("method", ""), message.get("params") or {}, writer)
                await reply({"id": request_id, "result": result})
            except RpcError as e:
                await reply({"id": request_id, "error": e.to_json()})
            except Exception as e:
                logger.exception("request %s failed", message.get("method"))
                await reply({"id": request_id, "error": {"code": "internal", "message": str(e)}})

        try:
            while line := await reader.readline():
                try:
                    message = protocol.decode(line)
                except ValueError:
                    continue
                asyncio.create_task(handle(message))
        except (ConnectionError, OSError):
            pass
        finally:
            self.subscribers.discard(writer)
            with contextlib.suppress(Exception):
                writer.close()

    async def shutdown(self) -> None:
        for worker in self.workers.values():
            worker.stop()
        await asyncio.sleep(0.2)
        for worker in self.workers.values():
            with contextlib.suppress(ProcessLookupError):
                if worker.process.returncode is None:
                    worker.process.kill()
