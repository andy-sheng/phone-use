"""Explicit, short-lived nearby discovery and pairing; no terminal prompts or stdout output.

iOS 27 can initiate pairing from Settings > Developer > Paired Macs. Devices that
advertise manual pairing can also be selected here. The normal network discovery
continues to show only authenticated peers, using the records saved by either flow.
"""

import asyncio
import platform
import socket
import time
import uuid
from dataclasses import dataclass
from typing import Any, Awaitable, Callable, Optional

from pymobiledevice3.bonjour import (
    MDNSResponder,
    REMOTEPAIRING_MANUAL_PAIRING_SERVICE_NAME,
    REMOTEPAIRING_PAIRABLE_HOST_SERVICE_NAME,
    ServiceInstance,
)
from pymobiledevice3.exceptions import RemotePairingCompletedError
from pymobiledevice3.remote.tunnel_service import (
    PairableHost,
    PairableHostInfo,
    RemotePairingManualPairingService,
)

from devicehubd import identity, system_bonjour
from devicehubd.protocol import RpcError
from devicehubd.transports import BROWSE_PAUSE, BROWSE_WINDOW, NETWORK_TTL

PAIRING_LIFETIME = 180.0
PAIRING_TIMEOUT = 90.0


@dataclass(frozen=True)
class PairedDevice:
    identifier: str
    name: str
    model: Optional[str] = None


class IOSManualPairingService(RemotePairingManualPairingService):
    async def _request_pair_consent(self) -> Any:
        # The upstream tvOS/visionOS flow calls input(). This daemon must never
        # read stdin or print a PIN prompt into a protocol stream.
        if not self.remote_device_model.startswith(("iPhone", "iPad")):
            raise RpcError("unsupported", "Nearby pairing supports iPhone and iPad")
        return await super()._request_pair_consent()


class WirelessPairing:
    def __init__(self, on_paired: Callable[[PairedDevice], Awaitable[None]]) -> None:
        self.session_id = str(uuid.uuid4())
        self.host_info = PairableHostInfo(name=f"{platform.node()} · {identity.display_name()}")
        self.on_paired = on_paired
        self.state = "waiting"
        self.pin: Optional[str] = None
        self.error: Optional[str] = None
        self.discovery_error: Optional[str] = None
        self.paired_device: Optional[PairedDevice] = None
        self._nearby: dict[str, tuple[ServiceInstance, float]] = {}
        self._tasks: set[asyncio.Task[Any]] = set()
        self._server: Optional[asyncio.AbstractServer] = None
        self._advertiser: Optional[MDNSResponder] = None
        self._cleanup_lock = asyncio.Lock()

    @property
    def active(self) -> bool:
        return self.state in {"waiting", "pairing"}

    def _spawn(self, coroutine: Any) -> None:
        task = asyncio.create_task(coroutine)
        self._tasks.add(task)
        task.add_done_callback(self._task_finished)

    def _task_finished(self, task: asyncio.Task[Any]) -> None:
        self._tasks.discard(task)
        # Consume failures even when a client closes without polling again.
        if not task.cancelled() and task.exception() is not None:
            self.state = "failed"
            self.pin = None
            self.error = "Nearby pairing stopped unexpectedly. Close this window and try again."

    async def start(self) -> None:
        try:
            # One dual-stack listener keeps the advertised port the same for
            # IPv4 and IPv6, including IPv6-only local networks.
            listener = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
            try:
                listener.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
                listener.bind(("::", 0))
                listener.setblocking(False)
                self._server = await asyncio.start_server(self._accept, sock=listener)
            except BaseException:
                listener.close()
                raise
            port = self._server.sockets[0].getsockname()[1]
            self._advertiser = MDNSResponder(
                REMOTEPAIRING_PAIRABLE_HOST_SERVICE_NAME,
                self.host_info.identifier, port, self.host_info.mdns_txt_records(),
            )
            await self._advertiser.__aenter__()
            self._spawn(self._browse())
            self._spawn(self._expire())
        except BaseException:
            await self.close()
            raise

    def snapshot(self) -> dict[str, Any]:
        now = time.monotonic()
        devices = []
        for identifier, (answer, seen) in self._nearby.items():
            if now - seen < NETWORK_TTL:
                devices.append({"id": identifier, "name": answer.properties.get("name") or "Nearby Apple device"})
        return {
            "sessionID": self.session_id, "state": self.state,
            "hostName": self.host_info.name, "pin": self.pin,
            "devices": sorted(devices, key=lambda item: (item["name"], item["id"])),
            "pairedUDID": self.paired_device.identifier if self.paired_device else None,
            "deviceName": self.paired_device.name if self.paired_device else None,
            "error": self.error, "discoveryError": self.discovery_error,
        }

    async def _browse(self) -> None:
        while self.active:
            try:
                async for answer in system_bonjour.iter_browse(REMOTEPAIRING_MANUAL_PAIRING_SERVICE_NAME, BROWSE_WINDOW):
                    identifier = answer.properties.get("identifier")
                    model = answer.properties.get("model", "")
                    if (identifier and answer.addresses and 0 < answer.port < 65536
                            and (not model or model.startswith(("iPhone", "iPad")))):
                        self._nearby[identifier] = (answer, time.monotonic())
                self.discovery_error = None
            except Exception:
                self.discovery_error = f"Nearby discovery failed. Check local network access for {identity.display_name()}."
            # Expire stale entries rather than keeping every device ever seen.
            now = time.monotonic()
            self._nearby = {key: value for key, value in self._nearby.items() if now - value[1] < NETWORK_TTL}
            await asyncio.sleep(BROWSE_PAUSE)

    async def _expire(self) -> None:
        await asyncio.sleep(PAIRING_LIFETIME)
        await self._fail("Pairing timed out. Open Paired Macs on the device and try again.")

    def pair(self, identifier: str) -> None:
        if self.state != "waiting":
            raise RpcError("pairingBusy", "Another pairing is in progress; close this window to cancel it")
        entry = self._nearby.get(identifier)
        if entry is None or time.monotonic() - entry[1] >= NETWORK_TTL:
            raise RpcError("deviceNotFound", "This nearby device is no longer available")
        self.state = "pairing"
        self._spawn(self._pair_manual(identifier, entry[0]))

    async def _pair_manual(self, identifier: str, answer: ServiceInstance) -> None:
        try:
            # A service may publish several interfaces. Try each address, but
            # never replay pairing after reaching a device and requesting consent.
            service = None
            for address in answer.addresses:
                candidate = IOSManualPairingService(identifier, address.full_ip, answer.port)
                try:
                    # connect() also pairs; only transport failures may try an alternative.
                    async with asyncio.timeout(PAIRING_TIMEOUT):
                        try:
                            await candidate.connect(autopair=True)
                        except RemotePairingCompletedError:
                            pass
                    service = candidate
                    break
                except OSError:
                    if candidate.handshake_info is not None:
                        raise
                finally:
                    await candidate.close()
            if service is None:
                raise ConnectionError("No nearby address is reachable")
            await self._complete(PairedDevice(identifier, answer.properties.get("name") or "iPhone / iPad",
                                              service.remote_device_model))
        except Exception:
            await self._fail("Pairing failed. Unlock the device, accept the pairing request, and try again.")

    def _accept(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        if self.state != "waiting":
            writer.close()
            return
        self.state = "pairing"
        self._spawn(self._pair_incoming(reader, writer))

    async def _pair_incoming(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        host = PairableHost(reader, writer, self.host_info)
        try:
            async with asyncio.timeout(PAIRING_TIMEOUT):
                peer = await host.accept(self._show_pin)
            if not peer.model.startswith(("iPhone", "iPad")):
                raise RpcError("unsupported", "Nearby pairing supports iPhone and iPad")
            # Persist only after successful code verification, never during discovery.
            host.save_pair_record()
            await self._complete(PairedDevice(peer.udid or peer.account_id, peer.name, peer.model))
        except Exception:
            await self._fail("Pairing failed. Check the code on the device and try again.")
        finally:
            await host.close()

    def _show_pin(self, pin: str) -> None:
        # Only the owning local RPC client receives this code. Never log it.
        self.pin = pin

    async def _complete(self, device: PairedDevice) -> None:
        self.pin = None
        self.paired_device = device
        await self.on_paired(device)
        self.state = "paired"
        await self._stop_activity()

    async def _fail(self, message: str) -> None:
        self.state = "failed"
        self.pin = None
        self.error = message
        await self._stop_activity()

    async def close(self) -> None:
        if self.active:
            self.state = "cancelled"
        self.pin = None
        await self._stop_activity()

    async def _stop_activity(self) -> None:
        async with self._cleanup_lock:
            current = asyncio.current_task()
            tasks = [task for task in self._tasks if task is not current]
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            if self._server is not None:
                self._server.close()
                await self._server.wait_closed()
                self._server = None
            if self._advertiser is not None:
                await self._advertiser.__aexit__(None, None, None)
                self._advertiser = None
