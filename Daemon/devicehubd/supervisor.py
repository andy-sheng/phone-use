"""Supervisor: tracks attached devices and their readiness, and runs one worker per open device.

Clients (the app, the MCP server, the CLI) connect to a Unix socket and speak the framing in
`protocol`. Methods:

* ``hello``, ``listDevices``, ``subscribe`` (then ``devicesChanged`` notifications)
* ``pair``, ``revealDeveloperMode``, ``mountDeveloperImage`` -- onboarding steps
* ``startWirelessPairing``, ``wirelessPairingStatus``, ``pairNearbyDevice``, ``stopWirelessPairing``
* ``openDevice`` -> ``{udid, productVersion, services}``; ``closeDevice``
* ``openService`` -> ``{port}``: a loopback port relaying to that device service
* ``startMirror`` -> ``{port, path}`` (iOS 27+); ``stopMirror``
* ``androidCommand`` -> platform-neutral screenshot/input replies (Android only)
"""

import asyncio
import contextlib
import json
import logging
import os
import sys
from dataclasses import dataclass, field
from pathlib import Path
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
from devicehubd.android import AndroidAttachment, AndroidDiscovery
from devicehubd.protocol import RpcError
from devicehubd.transports import (
    DISCOVERIES,
    NETWORK,
    NetworkDiscovery,
    discovery_for,
    has_wireless_pairing,
    pair_wireless,
)
from devicehubd.wireless_pairing import PairedDevice, WirelessPairing

logger = logging.getLogger("devicehubd")

POLL_INTERVAL = 1.5
REPROBE_INTERVAL = 5.0
WORKER_START_TIMEOUT = 90.0
# A transient `adb devices` failure (server restart, timeout) must not close every
# Android session; only this many consecutive failures count as detachment.
ANDROID_DISCOVERY_FAILURE_LIMIT = 3
ANDROID_STATE_ERRORS = {
    "unauthorized": "Unlock the Android device and accept this computer's USB debugging authorization",
    "offline": "ADB reports this Android device offline; reconnect it and check USB debugging",
    "noPermissions": "ADB cannot access this device; check host USB permissions or drivers",
}
WORKER_STOP_GRACE = 5.0
WORKER_TERMINATE_GRACE = 1.0
WORKER_KILL_GRACE = 2.0
# Native-resolution PNG responses can be several MB; asyncio's default is 64 KB.
WORKER_READ_LIMIT = 64 * 1024 * 1024
TUNNEL_MOUNTS_VERSION = Version("27.0")
# What USB probes learned, so devices that show up only on the network still have a name.
DEVICE_CACHE = Path.home() / "Library" / "Application Support" / "DeviceHub" / "devices.json"
CACHED_FIELDS = ("name", "product_type", "product_version", "build_version", "developer_mode")


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
    wireless: Optional[bool] = None
    session: str = "closed"
    error: Optional[str] = None
    probed_at: float = 0.0
    platform: str = "ios"
    adb_serial: Optional[str] = None
    adb_state: Optional[str] = None

    @property
    def image_needs_tunnel(self) -> bool:
        return self.platform == "ios" and self.product_version is not None and Version(self.product_version) >= TUNNEL_MOUNTS_VERSION

    @property
    def state(self) -> str:
        if not self.attached:
            return "disconnected"
        if self.platform == "android":
            return {"device": "ready", "unauthorized": "unauthorized", "offline": "offline"}.get(self.adb_state, "probing")
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
            "platform": self.platform,
            "adbSerial": self.adb_serial,
            "adbState": self.adb_state,
            "connection": self.connection,
            "name": self.name or self.product_type or self.udid,
            "productType": self.product_type,
            "productVersion": self.product_version,
            "buildVersion": self.build_version,
            "state": self.state,
            "paired": self.paired,
            "developerMode": self.developer_mode,
            "developerImage": self.developer_image,
            "wireless": self.wireless,
            "session": self.session,
            "error": self.error,
        }


def _load_cache() -> dict[str, dict[str, Any]]:
    try:
        cache = json.loads(DEVICE_CACHE.read_text())
    except (OSError, ValueError):
        return {}
    return cache if isinstance(cache, dict) else {}


def _save_cache(cache: dict[str, dict[str, Any]]) -> None:
    try:
        DEVICE_CACHE.parent.mkdir(parents=True, exist_ok=True)
        DEVICE_CACHE.write_text(json.dumps(cache, indent=2, ensure_ascii=False))
    except OSError as e:
        logger.warning("saving the device cache failed: %r", e)


@dataclass
class WorkerHandle:
    process: asyncio.subprocess.Process
    ready: asyncio.Future[dict[str, Any]]
    pending: dict[int, asyncio.Future[Any]] = field(default_factory=dict)
    next_id: int = 1
    info: dict[str, Any] = field(default_factory=dict)
    command_lock: asyncio.Lock = field(default_factory=asyncio.Lock)
    stopping: bool = False
    stop_task: Optional[asyncio.Task[None]] = None

    async def call(self, method: str, params: dict[str, Any], timeout: float = 60.0) -> Any:
        if self.stopping or self.process.returncode is not None or self.process.stdin is None:
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
        if self.stopping:
            return
        self.stopping = True
        if self.process.returncode is None and self.process.stdin is not None:
            self.process.stdin.close()
        self.stop_task = asyncio.create_task(self._reap())
        # Discovery may initiate a stop without a waiter. Consume/log exceptions
        # while retaining the failed task, so reopen still observes the failure.
        self.stop_task.add_done_callback(self._stop_finished)

    @staticmethod
    def _stop_finished(task: asyncio.Task[None]) -> None:
        if not task.cancelled() and (error := task.exception()) is not None:
            logger.warning("device worker shutdown failed: %s", error)

    async def _reap(self) -> None:
        # Completion means the process has actually exited, including controller
        # destruction and its final contact release; closing stdin alone is not enough.
        for timeout, signal_process in (
            (WORKER_STOP_GRACE, None),
            (WORKER_TERMINATE_GRACE, self.process.terminate),
            (WORKER_KILL_GRACE, self.process.kill),
        ):
            if self.process.returncode is not None:
                await self.process.wait()
                return
            if signal_process is not None:
                with contextlib.suppress(ProcessLookupError):
                    signal_process()
            try:
                await asyncio.wait_for(self.process.wait(), timeout)
                return
            except asyncio.TimeoutError:
                continue
        raise RpcError("workerStopTimeout", "The previous device worker has not exited; a replacement session was not started")

    async def wait_closed(self) -> None:
        self.stop()
        assert self.stop_task is not None
        # A cancelled client request must not cancel the shared shutdown barrier.
        await asyncio.shield(self.stop_task)


class Supervisor:
    def __init__(self) -> None:
        self.records: dict[str, DeviceRecord] = {}
        self.workers: dict[str, WorkerHandle] = {}
        self.subscribers: set[asyncio.StreamWriter] = set()
        self._device_locks: dict[str, asyncio.Lock] = {}
        self._probing: set[str] = set()
        self._wireless_failed: set[str] = set()
        self._cache: dict[str, dict[str, Any]] = _load_cache()
        self.android = AndroidDiscovery()
        self._android_seen: dict[str, AndroidAttachment] = {}
        self._android_failures = 0
        self._wireless_pairing: Optional[WirelessPairing] = None
        self._wireless_owner: Optional[asyncio.StreamWriter] = None
        self._wireless_lock = asyncio.Lock()

    # MARK: Device tracking

    def _lock(self, udid: str) -> asyncio.Lock:
        return self._device_locks.setdefault(udid, asyncio.Lock())

    async def monitor(self) -> None:
        while True:
            await self.poll_devices()
            await asyncio.sleep(POLL_INTERVAL)

    async def poll_devices(self) -> None:
        loop = asyncio.get_running_loop()
        seen: dict[str, str] = {}
        for discovery in DISCOVERIES:
            try:
                for attachment in await discovery.attached():
                    seen.setdefault(attachment.udid, attachment.connection)
            except Exception as e:
                logger.debug("%s discovery failed: %r", discovery.connection, e)
        android = await self._discover_android()
        seen.update({udid: item.connection for udid, item in android.items()})
        changed = False
        for udid, connection in seen.items():
            record = self.records.get(udid)
            if record is None or not record.attached or record.connection != connection:
                if record is not None and record.attached:
                    worker = self.workers.get(udid)
                    if worker is not None:
                        worker.stop()
                self.records[udid] = record = DeviceRecord(
                    udid, connection, name=record.name if record else None,
                    platform="android" if udid in android else "ios",
                )
                changed = True
            if udid in android:
                changed |= self._update_android_record(record, android[udid])
                if record.state == "ready" and not record.product_version and loop.time() - record.probed_at > REPROBE_INTERVAL:
                    self._schedule_probe(udid)
            elif record.state != "ready" and loop.time() - record.probed_at > REPROBE_INTERVAL:
                self._schedule_probe(udid)
        for udid, record in self.records.items():
            if record.attached and udid not in seen:
                record.attached = False
                record.session = "closed"
                changed = True
                worker = self.workers.get(udid)
                if worker is not None:
                    worker.stop()
        if changed:
            await self.broadcast()

    async def _discover_android(self) -> dict[str, AndroidAttachment]:
        try:
            attached = await self.android.attached()
        except Exception as e:
            self._android_failures += 1
            logger.warning("ADB discovery failed (%d in a row): %r", self._android_failures, e)
            if self._android_failures < ANDROID_DISCOVERY_FAILURE_LIMIT:
                return self._android_seen
            attached = []
        self._android_failures = 0
        self._android_seen = {attachment.udid: attachment for attachment in attached}
        return self._android_seen

    def _update_android_record(self, record: DeviceRecord, attachment: AndroidAttachment) -> bool:
        """Applies one `adb devices` row; returns whether the published record changed."""
        before = record.to_json()
        ready = attachment.state == "device"
        record.adb_serial, record.adb_state = attachment.serial, attachment.state
        record.name, record.product_type = attachment.name, attachment.model
        record.paired = record.developer_mode = ready
        record.wireless = record.connection == NETWORK
        if not ready:
            record.error = ANDROID_STATE_ERRORS.get(attachment.state, f"Android device is not ready: {attachment.state}")
        elif before["adbState"] != "device":
            record.error = None
        if record.state != "ready":
            worker = self.workers.get(record.udid)
            if worker is not None:
                worker.stop()
                record.session = "closed"
        return record.to_json() != before

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
        if record.platform == "android":
            if record.adb_state == "device" and record.adb_serial:
                try:
                    record.product_version = await self.android.version(record.adb_serial)
                except Exception as e:
                    logger.debug("Android version probe failed: %r", e)
        elif (record.connection == NETWORK
              and not discovery_for(NETWORK).has_system_connection(record.udid)):
            self._probe_network(record)
        else:
            await self._probe_lockdown(record)
        if record.to_json() != before:
            await self.broadcast()

    def _probe_network(self, record: DeviceRecord) -> None:
        """Use cached metadata for authenticated RemotePairing peers without a system lockdown link."""
        for key, value in self._cache.get(record.udid, {}).items():
            if key in CACHED_FIELDS and value is not None:
                setattr(record, key, value)
        record.paired = True
        record.wireless = True
        if record.developer_mode is None:
            record.developer_mode = True
        # The worker mounts the image over the tunnel when it is missing.
        record.developer_image = True

    async def _probe_lockdown(self, record: DeviceRecord) -> None:
        udid = record.udid
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
                if record.connection == NETWORK:
                    record.wireless = True
                else:
                    await self._ensure_wireless(record, lockdown)
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
        self._remember(record)

    async def _ensure_wireless(self, record: DeviceRecord, lockdown: Any) -> None:
        """Pairs for Wi-Fi while the device is on the cable; the device shows no prompt for it."""
        if record.udid not in self._wireless_failed and not has_wireless_pairing(record.udid):
            try:
                await pair_wireless(lockdown)
                logger.info("paired %s for Wi-Fi", record.udid)
            except Exception as e:
                self._wireless_failed.add(record.udid)
                logger.warning("Wi-Fi pairing of %s failed: %r", record.udid, e)
        record.wireless = has_wireless_pairing(record.udid)

    def _remember(self, record: DeviceRecord) -> None:
        entry = {key: getattr(record, key) for key in CACHED_FIELDS}
        if record.product_type is None or self._cache.get(record.udid) == entry:
            return
        self._cache[record.udid] = entry
        _save_cache(self._cache)

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

    async def start_wireless_pairing(self, writer: asyncio.StreamWriter) -> dict[str, Any]:
        async with self._wireless_lock:
            # serve_client dispatches requests in tasks. EOF can close the
            # socket before a queued start request gets its first turn.
            if writer.is_closing():
                raise RpcError("disconnected", "The nearby pairing client disconnected")
            if self._wireless_pairing is not None:
                if self._wireless_pairing.active:
                    raise RpcError("pairingBusy", "A nearby pairing window is already open")
                await self._wireless_pairing.close()
            pairing = WirelessPairing(self._wireless_paired)
            self._wireless_pairing, self._wireless_owner = pairing, writer
            try:
                await pairing.start()
            except Exception as e:
                raise RpcError("discoveryFailed", "Cannot start nearby pairing. Check local network access for phone-use.") from e
            return pairing.snapshot()

    def wireless_pairing(self, params: dict[str, Any], writer: asyncio.StreamWriter) -> WirelessPairing:
        pairing = self._wireless_pairing
        if (pairing is None or self._wireless_owner is not writer
                or params.get("sessionID") != pairing.session_id):
            raise RpcError("pairingNotFound", "This nearby pairing session has ended")
        return pairing

    async def stop_wireless_pairing(self, writer: asyncio.StreamWriter, session_id: Optional[str] = None) -> None:
        async with self._wireless_lock:
            pairing = self._wireless_pairing
            if (pairing is not None and self._wireless_owner is writer
                    and (session_id is None or session_id == pairing.session_id)):
                await pairing.close()
                self._wireless_pairing = self._wireless_owner = None

    async def _wireless_paired(self, device: PairedDevice) -> None:
        for discovery in DISCOVERIES:
            if isinstance(discovery, NetworkDiscovery):
                discovery.remember(device.identifier)
        record = self.records.get(device.identifier)
        if record is None or not record.attached:
            record = DeviceRecord(device.identifier, NETWORK)
            self.records[device.identifier] = record
        record.paired = record.wireless = True
        if record.connection == NETWORK:
            self._probe_network(record)
            record.developer_mode = True
        record.name, record.product_type = device.name, device.model
        self._remember(record)
        await self.broadcast()

    def _ios_record(self, udid: Optional[str]) -> DeviceRecord:
        record = self._record(udid)
        if record.platform != "ios":
            raise RpcError("unsupported", "This service is only available for iOS devices; Android uses USB debugging")
        return record

    async def pair(self, udid: str) -> None:
        record = self._ios_record(udid)
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
        record = self._ios_record(udid)
        lockdown = await discovery_for(record.connection).lockdown(udid)
        try:
            await AmfiService(lockdown).reveal_developer_mode_option_in_ui()
        finally:
            with contextlib.suppress(Exception):
                await lockdown.close()

    async def mount_developer_image(self, udid: str) -> None:
        record = self._ios_record(udid)
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
        self._record(udid)
        async with self._lock(udid):
            record = self._record(udid)
            worker = self.workers.get(udid)
            if worker is not None and worker.stopping:
                await worker.wait_closed()
                if self.workers.get(udid) is worker:
                    del self.workers[udid]
                worker = None
                record = self._record(udid)
            if worker is None or worker.process.returncode is not None:
                if record.state == "probing" or record.state == "developerImageMissing":
                    await self.probe(udid)
                if record.state != "ready":
                    raise RpcError("notReady", f"{record.to_json()['name']} is not ready: {record.state}")
                worker = await self._spawn_worker(record)
        info = await asyncio.wait_for(asyncio.shield(worker.ready), WORKER_START_TIMEOUT)
        async with self._lock(udid):
            self._record(udid)
            if self.workers.get(udid) is not worker or worker.stopping or worker.process.returncode is not None:
                raise RpcError("disconnected", "The device session closed while it was opening")
        result = {"udid": udid, "platform": record.platform,
                  "productVersion": info.get("productVersion") or record.product_version, "services": info.get("services", [])}
        if record.platform == "android":
            result["display"] = info["display"]
        return result

    async def _spawn_worker(self, record: DeviceRecord) -> WorkerHandle:
        if record.platform == "android":
            if not self.android.adb_path or not record.adb_serial:
                raise RpcError("adbUnavailable", "ADB not found; install Android platform-tools or set DEVICEHUB_ADB")
            arguments = ["devicehubd.android_worker", "--adb", self.android.adb_path, "--serial", record.adb_serial]
        else:
            arguments = ["devicehubd.worker", "--udid", record.udid, "--connection", record.connection]
        process = await asyncio.create_subprocess_exec(
            sys.executable, "-m", *arguments,
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
            limit=WORKER_READ_LIMIT,
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
        while True:
            try:
                line = await worker.process.stdout.readline()
            except (ValueError, OSError, asyncio.IncompleteReadError) as error:
                failure = {"code": "workerProtocolError", "message": f"Cannot read device worker reply: {error}"}
                worker.stop()
                break
            if not line:
                break
            try:
                message = protocol.decode(line)
            except ValueError:
                continue
            event = message.get("event")
            if event == "ready":
                worker.info = message
                if not worker.ready.done():
                    if worker.stopping:
                        worker.ready.set_exception(RpcError("disconnected", "The device session is closing"))
                    else:
                        worker.ready.set_result(message)
                if self.workers.get(record.udid) is worker and not worker.stopping:
                    record.session = "open"
                    if record.platform == "ios":
                        record.developer_image = True
                    record.product_version = message.get("productVersion") or record.product_version
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
        if not udid:
            raise RpcError("invalidParams", "Missing udid")
        async with self._lock(udid):
            worker = self.workers.get(udid)
            if worker is not None:
                # Keep the worker registered and the device lock held until exit.
                # A simultaneous open must not overlap a late touch release from
                # the old Maa controller with input from a replacement controller.
                await worker.wait_closed()
                if self.workers.get(udid) is worker:
                    del self.workers[udid]
            record = self.records.get(udid)
            if record is not None:
                record.session = "closed"
                await self.broadcast()

    # MARK: Client connections

    async def android_command(self, params: dict[str, Any]) -> Any:
        if any(not isinstance(value, str) for value in params.values()):
            raise RpcError("invalidParams", "Android command parameters must be strings")
        record = self._record(params.get("udid"))
        if record.platform != "android":
            raise RpcError("unsupported", "androidCommand requires an Android device")
        worker = await self._worker(record.udid)
        # Queue one operation at a time even when GUI and automation share a device.
        async with worker.command_lock:
            try:
                return await worker.call("androidCommand", params, timeout=65)
            except asyncio.TimeoutError as error:
                # The action may already have executed. Close the session rather
                # than replaying it or letting subsequent input race a late result.
                worker.stop()
                raise RpcError("timeout", "Android command timed out; the session was closed without replaying it") from error

    async def android_video(self, method: str, params: dict[str, Any]) -> Any:
        if any(not isinstance(value, str) for value in params.values()):
            raise RpcError("invalidParams", "Android video parameters must be strings")
        udid = params.get("udid")
        if method == "stopAndroidVideo":
            if not isinstance(udid, str) or not udid.startswith("android:") or not params.get("token"):
                raise RpcError("invalidParams", "Missing Android device or video token")
            # A delayed stop must never open a replacement device worker. The
            # worker additionally checks the instance token before stopping it.
            worker = self.workers.get(udid)
            if worker is None or worker.stopping or worker.process.returncode is not None:
                return {}
            return await worker.call(method, {"token": params["token"]}, timeout=35)
        record = self._record(udid)
        if record.platform != "android":
            raise RpcError("unsupported", "Android video requires an Android device")
        worker = await self._worker(record.udid)
        # Serialize with control requests so worker stdin has no hidden queue of
        # long-running actions ahead of the bounded video startup timeout.
        async with worker.command_lock:
            return await worker.call(method, {}, timeout=35)

    async def dispatch(self, method: str, params: dict[str, Any], writer: asyncio.StreamWriter) -> Any:
        udid = params.get("udid")
        if method == "hello":
            return {"version": VERSION, "pid": os.getpid()}
        if method == "listDevices":
            return {"devices": self.device_list()}
        if method == "subscribe":
            self.subscribers.add(writer)
            return {"devices": self.device_list()}
        if method == "startWirelessPairing":
            return await self.start_wireless_pairing(writer)
        if method == "wirelessPairingStatus":
            return self.wireless_pairing(params, writer).snapshot()
        if method == "pairNearbyDevice":
            identifier = params.get("deviceID")
            if not isinstance(identifier, str) or not identifier:
                raise RpcError("invalidParams", "Missing nearby device ID")
            self.wireless_pairing(params, writer).pair(identifier)
            return {}
        if method == "stopWirelessPairing":
            session_id = params.get("sessionID")
            if not isinstance(session_id, str) or not session_id:
                raise RpcError("invalidParams", "Missing nearby pairing session ID")
            await self.stop_wireless_pairing(writer, session_id)
            return {}
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
        if method == "androidCommand":
            return await self.android_command(params)
        if method in {"startAndroidVideo", "stopAndroidVideo"}:
            return await self.android_video(method, params)
        if method == "openService":
            self._ios_record(udid)
            worker = await self._worker(udid)
            return await worker.call("forward", {"service": params.get("service")})
        if method == "startMirror":
            self._ios_record(udid)
            worker = await self._worker(udid)
            return await worker.call("startMirror", {}, timeout=60)
        if method == "stopMirror":
            self._ios_record(udid)
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
            await self.stop_wireless_pairing(writer)
            with contextlib.suppress(Exception):
                writer.close()

    async def shutdown(self) -> None:
        if self._wireless_owner is not None:
            await self.stop_wireless_pairing(self._wireless_owner)
        workers = list(self.workers.values())
        await asyncio.gather(*(worker.wait_closed() for worker in workers), return_exceptions=True)
