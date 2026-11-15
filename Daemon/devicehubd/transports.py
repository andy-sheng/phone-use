"""How devices are found and how a tunnel to them is built, one implementation per link type.

* ``usb``: usbmuxd lists the device and the tunnel is CoreDeviceProxy over lockdown.
* ``network``: already-trusted devices exposed by the system's usbmuxd over Wi-Fi, plus
  RemotePairing advertisements matched to this tool's own pairing records. The system
  path reuses its existing trust without importing Xcode keys or creating a new pairing.
  Advertisements are browsed through the system mDNSResponder (`system_bonjour`), so a
  VPN that owns the multicast route does not hide them. Both sources drop a device while
  it sleeps although it is still reachable, so sightings are kept for a grace period, and
  a quiet RemotePairing peer is kept alive by a TCP check of its last advertised address.

The supervisor, the worker and the Swift client only ever see the ``connection`` string.
"""

import asyncio
import contextlib
import json
import logging
import os
import time
from dataclasses import dataclass
from typing import Any, Optional, Protocol

from pymobiledevice3.bonjour import REMOTEPAIRING_SERVICE_NAME
from pymobiledevice3.exceptions import ConnectionTerminatedError, InvalidServiceError, RemotePairingCompletedError
from pymobiledevice3.lockdown import UsbmuxLockdownClient, create_using_usbmux
from pymobiledevice3.pair_records import iter_remote_pair_records_by_identifier
from pymobiledevice3.remote import userspace_tunnel
from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService
from pymobiledevice3.remote.tunnel_service import (
    CoreDeviceTunnelProxy,
    PEER_ALT_IRK_KEY,
    RemotePairingLockdownService,
    _match_remote_pair_record,
    create_core_device_tunnel_service_using_remotepairing,
)
from pymobiledevice3.remote.userspace_tunnel import UserspaceRsdTunnel
from pymobiledevice3.usbmux import list_devices

from devicehubd import system_bonjour
from devicehubd.protocol import RpcError

logger = logging.getLogger("devicehubd")

USB = "usb"
NETWORK = "network"

BROWSE_WINDOW = 3.0
BROWSE_PAUSE = 2.0
# A RemotePairing peer counts as on the network while it answered a browse or a
# reachability check this recently.
NETWORK_TTL = 30.0
# usbmuxd drops sleeping Wi-Fi devices for about a minute at a time and offers no way to
# check them in between, so its sightings get a longer grace period.
SYSTEM_NETWORK_TTL = 90.0
# A peer that stopped advertising is checked once its last sighting is this old.
REACHABILITY_AFTER = 10.0
REACHABILITY_TIMEOUT = 1.5
# The supervisor hands a Wi-Fi worker the peer's last advertised addresses, so a device
# that is asleep (and silent on Bonjour) can still be opened.
ENDPOINTS_ENV = "DEVICEHUB_NETWORK_ENDPOINTS"
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
        # Listed by usbmuxd right now (needed to open lockdown) vs. when it was last listed.
        self._system_devices: set[str] = set()
        self._system_seen: dict[str, float] = {}
        self._endpoints: dict[str, list[tuple[str, int]]] = {}

    def has_system_connection(self, udid: str) -> bool:
        return udid in self._system_devices

    def endpoints(self, udid: str) -> list[tuple[str, int]]:
        """The addresses the RemotePairing peer advertised most recently."""
        return list(self._endpoints.get(udid, ()))

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
        for udid in self._system_devices:
            self._system_seen[udid] = now
        seen = {udid for sightings, ttl in ((self._seen, NETWORK_TTL), (self._system_seen, SYSTEM_NETWORK_TTL))
                for udid, last_seen in sightings.items() if now - last_seen < ttl}
        return [Attachment(udid, NETWORK) for udid in sorted(seen)]

    async def _browse(self) -> None:
        while True:
            identities = wireless_identities()
            if identities:
                answered: set[str] = set()
                try:
                    async with contextlib.aclosing(system_bonjour.iter_browse(
                            REMOTEPAIRING_SERVICE_NAME, BROWSE_WINDOW)) as answers:
                        async for answer in answers:
                            udid = _match_remote_pair_record(answer, identities)
                            if udid is not None:
                                answered.add(udid)
                                self._seen[udid] = time.monotonic()
                                if answer.addresses:
                                    self._endpoints[udid] = [(address.full_ip, answer.port)
                                                             for address in answer.addresses]
                except Exception as e:
                    logger.debug("RemotePairing browse failed: %r", e)
                await self._check_quiet_peers(set(identities) - answered)
            await asyncio.sleep(BROWSE_PAUSE)

    async def _check_quiet_peers(self, udids: set[str]) -> None:
        """A sleeping device stops advertising long before it stops accepting connections.

        Only peers still within their grace period are checked, so a device that has really
        left expires as before and comes back through a browse answer.
        """
        now = time.monotonic()
        due = [udid for udid in sorted(udids)
               if udid in self._endpoints and REACHABILITY_AFTER <= now - self._seen.get(udid, -NETWORK_TTL) < NETWORK_TTL]
        results = await asyncio.gather(*(_reachable(self._endpoints[udid]) for udid in due))
        for udid, reachable in zip(due, results):
            if reachable:
                self._seen[udid] = time.monotonic()

    async def lockdown(self, udid: str) -> UsbmuxLockdownClient:
        if self.has_system_connection(udid):
            return await create_using_usbmux(serial=udid, autopair=False, connection_type="Network")
        raise RpcError("needsUsb", "This step needs the device connected to this Mac with a USB cable")


async def _reachable(endpoints: list[tuple[str, int]]) -> bool:
    """A plain TCP connect: no RemotePairing handshake, nothing for the device to show."""
    for host, port in endpoints:
        try:
            _, writer = await asyncio.wait_for(asyncio.open_connection(host, port), REACHABILITY_TIMEOUT)
        except (OSError, asyncio.TimeoutError):
            continue
        writer.close()
        with contextlib.suppress(Exception):
            await writer.wait_closed()
        return True
    return False


def _known_endpoints() -> list[tuple[str, int]]:
    try:
        value = json.loads(os.environ.get(ENDPOINTS_ENV) or "[]")
        return [(str(host), int(port)) for host, port in value]
    except (TypeError, ValueError):
        return []


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
    return await _remote_pairing_service(serial), None


async def _remote_pairing_service(udid: Optional[str]) -> Any:
    """Connect over this tool's RemotePairing record.

    The last advertised addresses come first: a sleeping device no longer answers Bonjour but
    still accepts the connection. A fresh browse covers devices whose address changed.
    """
    alt_irk = wireless_identities().get(udid or "")
    if alt_irk is None:
        raise ConnectionError(f"{udid} is not listed by macOS over Wi-Fi right now and is not paired for "
                              "Wi-Fi with phone-use; wake the device, or connect it with USB once to pair")
    tried: set[tuple[str, int]] = set()

    async def attempt(host: str, port: int) -> Any:
        tried.add((host, port))
        try:
            return await create_core_device_tunnel_service_using_remotepairing(udid, host, port)
        except (ConnectionTerminatedError, asyncio.IncompleteReadError, asyncio.TimeoutError, OSError) as e:
            logger.debug("RemotePairing %s@%s:%s failed: %r", udid, host, port, e)
            return None

    for host, port in _known_endpoints():
        if (service := await attempt(host, port)) is not None:
            return service
    async with contextlib.aclosing(system_bonjour.iter_browse(
            REMOTEPAIRING_SERVICE_NAME, NETWORK_CONNECT_TIMEOUT)) as answers:
        async for answer in answers:
            if _match_remote_pair_record(answer, {udid: alt_irk}) is None:
                continue
            for address in answer.addresses:
                if (address.full_ip, answer.port) not in tried:
                    if (service := await attempt(address.full_ip, answer.port)) is not None:
                        return service
    raise ConnectionError(f"{udid} did not answer over the network")


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
