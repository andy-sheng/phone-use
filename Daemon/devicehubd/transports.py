"""How devices are found and how a tunnel to them is built, one implementation per link type.

* ``usb``: usbmuxd lists the device and the tunnel is CoreDeviceProxy over lockdown.
* ``network``: already-trusted devices exposed by the system's usbmuxd over Wi-Fi, plus
  RemotePairing advertisements matched to this tool's own pairing records. The system
  path reuses its existing trust without importing Xcode keys or creating a new pairing.

The supervisor, the worker and the Swift client only ever see the ``connection`` string.
"""

import asyncio
import contextlib
import logging
import time
from dataclasses import dataclass
from typing import Any, Optional, Protocol

from pymobiledevice3.bonjour import iter_browse_remotepairing
from pymobiledevice3.exceptions import InvalidServiceError, RemotePairingCompletedError
from pymobiledevice3.lockdown import UsbmuxLockdownClient, create_using_usbmux
from pymobiledevice3.pair_records import iter_remote_pair_records_by_identifier
from pymobiledevice3.remote import userspace_tunnel
from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService
from pymobiledevice3.remote.tunnel_service import (
    CoreDeviceTunnelProxy,
    PEER_ALT_IRK_KEY,
    RemotePairingLockdownService,
    _match_remote_pair_record,
    get_remote_pairing_tunnel_services,
)
from pymobiledevice3.remote.userspace_tunnel import UserspaceRsdTunnel
from pymobiledevice3.usbmux import list_devices

from devicehubd.protocol import RpcError

logger = logging.getLogger("devicehubd")

USB = "usb"
NETWORK = "network"

BROWSE_WINDOW = 3.0
BROWSE_PAUSE = 2.0
# A device counts as on the network while it answered a browse this recently.
NETWORK_TTL = 15.0
NETWORK_CONNECT_TIMEOUT = 10.0


@dataclass(frozen=True)
class Attachment:
    udid: str
    connection: str


class Discovery(Protocol):
    connection: str

    async def attached(self) -> list[Attachment]: ...

    async def lockdown(self, udid: str) -> UsbmuxLockdownClient: ...


class Tunnel(Protocol):
    async def open(self) -> RemoteServiceDiscoveryService: ...

    @property
    def rsd(self) -> Optional[RemoteServiceDiscoveryService]: ...

    async def close(self) -> None: ...


# MARK: USB


class UsbDiscovery:
    connection = USB

    async def attached(self) -> list[Attachment]:
        devices = await list_devices()
        return [Attachment(device.serial, USB) for device in devices if device.is_usb]

    async def lockdown(self, udid: str) -> UsbmuxLockdownClient:
        return await create_using_usbmux(serial=udid, autopair=False, connection_type="USB")


class UsbTunnel:
    """CoreDeviceProxy over usbmuxd with an in-process TCP/IP stack: no root, no CoreDevice."""

    def __init__(self, udid: str) -> None:
        self._tunnel = UserspaceRsdTunnel(serial=udid, autopair=False, remotepairing_fallback=False)

    async def open(self) -> RemoteServiceDiscoveryService:
        return await self._tunnel.aopen()

    @property
    def rsd(self) -> Optional[RemoteServiceDiscoveryService]:
        return self._tunnel.rsd

    async def close(self) -> None:
        await self._tunnel.aclose()


# MARK: Network


def wireless_identities() -> dict[str, bytes]:
    """The altIRK of every device with a RemotePairing record, keyed by UDID."""
    return {
        udid: record[PEER_ALT_IRK_KEY]
        for udid, _, record in iter_remote_pair_records_by_identifier()
        if PEER_ALT_IRK_KEY in record
    }


def has_wireless_pairing(udid: str) -> bool:
    return udid in wireless_identities()


async def pair_wireless(lockdown: Any) -> None:
    """Create the device's RemotePairing record over an already trusted USB lockdown connection."""
    service = await RemotePairingLockdownService.create(lockdown)
    try:
        # The device closes the channel as soon as pair-setup completes.
        with contextlib.suppress(RemotePairingCompletedError):
            await service.connect(autopair=True)
    finally:
        await service.close()


class NetworkDiscovery:
    connection = NETWORK

    def __init__(self) -> None:
        self._seen: dict[str, float] = {}
        self._task: Optional[asyncio.Task[None]] = None
        self._system_devices: set[str] = set()

    def has_system_connection(self, udid: str) -> bool:
        return udid in self._system_devices

    def remember(self, udid: str) -> None:
        """Bridge successful nearby pairing into normal discovery until its next browse."""
        self._seen[udid] = time.monotonic()

    async def attached(self) -> list[Attachment]:
        if self._task is None or self._task.done():
            self._task = asyncio.create_task(self._browse())
        # Xcode/Finder can already have a trusted Wi-Fi connection even when
        # there are no pymobiledevice3 RemotePairing records at all.
        try:
            self._system_devices = {device.serial for device in await list_devices()
                                    if device.connection_type == "Network"}
        except Exception as error:
            logger.debug("system Wi-Fi discovery failed: %r", error)
            self._system_devices = set()
        now = time.monotonic()
        seen = {udid for udid, last_seen in self._seen.items() if now - last_seen < NETWORK_TTL}
        return [Attachment(udid, NETWORK) for udid in sorted(seen | self._system_devices)]

    async def _browse(self) -> None:
        while True:
            identities = wireless_identities()
            if identities:
                try:
                    async for answer in iter_browse_remotepairing(timeout=BROWSE_WINDOW):
                        udid = _match_remote_pair_record(answer, identities)
                        if udid is not None:
                            self._seen[udid] = time.monotonic()
                except Exception as e:
                    logger.debug("RemotePairing browse failed: %r", e)
            await asyncio.sleep(BROWSE_PAUSE)

    async def lockdown(self, udid: str) -> UsbmuxLockdownClient:
        if self.has_system_connection(udid):
            return await create_using_usbmux(serial=udid, autopair=False, connection_type="Network")
        raise RpcError("needsUsb", "This step needs the device connected to this Mac with a USB cable")


async def _network_tunnel_provider(serial: Optional[str], autopair: bool, remotepairing_fallback: bool) -> Any:
    # A worker owns one tunnel, so this hook can use the same in-process stack
    # with CoreDeviceProxy over an existing system Wi-Fi connection as over USB.
    try:
        devices = await list_devices()
    except Exception as error:
        logger.debug("system Wi-Fi discovery failed while opening a tunnel: %r", error)
        devices = []
    if any(device.serial == serial and device.connection_type == "Network" for device in devices):
        lockdown = await create_using_usbmux(serial=serial, autopair=False, connection_type="Network")
        try:
            if not lockdown.paired:
                raise RpcError("notReady", "The system Wi-Fi connection is not trusted")
            return await CoreDeviceTunnelProxy.create(lockdown), lockdown
        except InvalidServiceError:
            # Older systems may expose network lockdown without CoreDeviceProxy.
            # Preserve their existing RemotePairing transport.
            await lockdown.close()
        except BaseException:
            await lockdown.close()
            raise
    services = await get_remote_pairing_tunnel_services(bonjour_timeout=NETWORK_CONNECT_TIMEOUT, udid=serial)
    if not services:
        raise ConnectionError(f"{serial} did not answer over the network")
    # One answer lists several addresses and each yields a connected service; keep the first.
    for extra in services[1:]:
        with contextlib.suppress(Exception):
            await extra.close()
    return services[0], None


class NetworkTunnel:
    """System Wi-Fi or RemotePairing into the same TCP/IP stack as `UsbTunnel`."""

    def __init__(self, udid: str) -> None:
        # UserspaceRsdTunnel only reaches devices through usbmuxd. Its provider hook is process-wide,
        # which is safe because a worker process holds exactly one tunnel.
        userspace_tunnel._create_no_root_tunnel_provider = _network_tunnel_provider
        self._tunnel = UserspaceRsdTunnel(serial=udid, autopair=False)

    async def open(self) -> RemoteServiceDiscoveryService:
        return await self._tunnel.aopen()

    @property
    def rsd(self) -> Optional[RemoteServiceDiscoveryService]:
        return self._tunnel.rsd

    async def close(self) -> None:
        await self._tunnel.aclose()


# USB comes first: a device reachable both ways is used over the cable.
DISCOVERIES: list[Discovery] = [UsbDiscovery(), NetworkDiscovery()]


def discovery_for(connection: str) -> Discovery:
    for discovery in DISCOVERIES:
        if discovery.connection == connection:
            return discovery
    raise ValueError(f"unsupported connection type: {connection}")


def make_tunnel(connection: str, udid: str) -> Tunnel:
    if connection == USB:
        return UsbTunnel(udid)
    if connection == NETWORK:
        return NetworkTunnel(udid)
    raise ValueError(f"unsupported connection type: {connection}")
