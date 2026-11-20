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
import plistlib
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional, Protocol

from pymobiledevice3.bonjour import REMOTEPAIRING_SERVICE_NAME
from pymobiledevice3.exceptions import ConnectionTerminatedError, InvalidServiceError
from pymobiledevice3.lockdown import UsbmuxLockdownClient, create_using_usbmux
from pymobiledevice3.pair_records import (
    PAIRING_RECORD_EXT,
    create_pairing_records_cache_folder,
    get_remote_pairing_record_filename,
    iter_remote_pair_records_by_identifier,
)
from pymobiledevice3.remote import userspace_tunnel
from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService
from pymobiledevice3.remote.tunnel_service import (
    CoreDeviceTunnelProxy,
    PEER_ALT_IRK_KEY,
    PairingDataComponentTLVBuf,
    PairingDataComponentType,
    RemotePairingLockdownService,
    RemotePairingTunnelService,
    _match_remote_pair_record,
)
from pymobiledevice3.remote.userspace_tunnel import UserspaceRsdTunnel
from pymobiledevice3.usbmux import list_devices

from devicehubd import identity, system_bonjour
from devicehubd.protocol import RpcError

logger = logging.getLogger("devicehubd")

USB = "usb"
NETWORK = "network"

# The RPC error code for a Wi-Fi pairing the device refused.
WIRELESS_REJECTED = "wirelessPairingRejected"
# Kept in the shared RemotePairing record next to pymobiledevice3's own keys.
REJECTED_AT_KEY = "devicehubRejectedAt"
# The pairing TLV error a device answers pair-verify with when it does not know the host's key.
AUTHENTICATION_ERROR = b"\x02"

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


async def pair_wireless(lockdown: Any) -> bool:
    """Make sure the device accepts this Mac's RemotePairing record, over a trusted USB lockdown.

    A record can exist and still be refused over Wi-Fi: the device forgot this Mac, or this Mac's
    hostname-derived host identifier changed since pairing. The same pair-verify runs here first;
    only a refused or missing record is replaced, and pairing over lockdown shows no prompt.
    Returns whether a new record was written.
    """
    service = await RemotePairingLockdownService.create(lockdown)
    try:
        # `connect()` cannot tell a verified record from a refused one without autopair, and with
        # autopair it pairs under a refused record's identifier, then saves a record without it.
        own_identifier = service.identifier
        await service._attempt_pair_verify()
        if await service._validate_pairing():
            return False
        service.identifier = own_identifier
        await service._pair()
        _pin_host_identifier(service.pair_record_path, own_identifier)
        return True
    finally:
        await service.close()


def _pin_host_identifier(path: Path, host_identifier: str) -> None:
    """Pair-verify presents the record's identifier instead of one derived from the current hostname."""
    record = plistlib.loads(path.read_bytes())
    record["host_identifier"] = host_identifier
    path.write_bytes(plistlib.dumps(record))


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
        logger.warning("system Wi-Fi discovery failed while opening a tunnel: %r", error)
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


class PairingRejected(Exception):
    """The device answered pair-verify and does not know this record's key."""


class _CheckedRemotePairing(RemotePairingTunnelService):
    """RemotePairing over Wi-Fi that tells a refused record from a lost connection.

    Upstream raises the same bare `ConnectionTerminatedError` for both.
    """

    def __init__(self, remote_identifier: str, hostname: str, port: int) -> None:
        super().__init__(remote_identifier, hostname, port)
        self.stage = "connect"
        self.pairing_error: Optional[bytes] = None
        self._last_pairing_data = b""

    async def _attempt_pair_verify(self) -> None:
        self.stage = "handshake"
        await super()._attempt_pair_verify()
        self.stage = "verify"

    async def _receive_pairing_data(self) -> bytes:
        self._last_pairing_data = await super()._receive_pairing_data()
        return self._last_pairing_data

    async def _validate_pairing(self) -> bool:
        if await super()._validate_pairing():
            return True
        components = self.decode_tlv(PairingDataComponentTLVBuf.parse(self._last_pairing_data))
        self.pairing_error = components.get(PairingDataComponentType.ERROR)
        # Other errors (busy, back off, unavailable) can pass; only this one is about the key.
        if self.pairing_error == AUTHENTICATION_ERROR:
            raise PairingRejected()
        return False


async def _open_remote_pairing(udid: Optional[str], host: str, port: int) -> RemotePairingTunnelService:
    service = _CheckedRemotePairing(udid or "", host, port)
    try:
        await service.connect(autopair=False)
    except PairingRejected:
        raise
    except Exception as e:
        logger.warning("RemotePairing connection failed host=%s port=%s stage=%s pairing_error=%s error=%r",
                       host, port, service.stage,
                       service.pairing_error.hex() if service.pairing_error is not None else "none", e)
        raise
    return service


def _remote_record_path(udid: str) -> Path:
    return create_pairing_records_cache_folder() / f"{get_remote_pairing_record_filename(udid)}.{PAIRING_RECORD_EXT}"


def _read_remote_record(udid: str) -> Optional[dict[str, Any]]:
    try:
        return plistlib.loads(_remote_record_path(udid).read_bytes())
    except (OSError, ValueError, plistlib.InvalidFileException):
        return None


def mark_wireless_rejected(udid: Optional[str]) -> None:
    """Note the refusal in the shared record, so every app using it stops offering Wi-Fi.

    Pairing again rewrites the record without this key.
    """
    record = _read_remote_record(udid or "")
    if record is None:
        return
    record[REJECTED_AT_KEY] = time.time()
    with contextlib.suppress(OSError):
        _remote_record_path(udid or "").write_bytes(plistlib.dumps(record))


def wireless_rejected(udid: str) -> bool:
    record = _read_remote_record(udid)
    return record is not None and REJECTED_AT_KEY in record


def forget_wireless_pairing(udid: str) -> None:
    with contextlib.suppress(OSError):
        _remote_record_path(udid).unlink(missing_ok=True)


async def _remote_pairing_service(udid: Optional[str]) -> Any:
    """Connect over this tool's RemotePairing record.

    The last advertised addresses come first: a sleeping device no longer answers Bonjour but
    still accepts the connection. A fresh browse covers devices whose address changed.
    """
    alt_irk = wireless_identities().get(udid or "")
    if alt_irk is None:
        raise ConnectionError(f"{udid} is not listed by macOS over Wi-Fi right now and is not paired for "
                              f"Wi-Fi with {identity.display_name()}; wake the device, or connect it with USB once to pair")
    tried: set[tuple[str, int]] = set()

    async def attempt(host: str, port: int) -> Any:
        tried.add((host, port))
        logger.info("RemotePairing connection attempt host=%s port=%s", host, port)
        try:
            return await _open_remote_pairing(udid, host, port)
        except PairingRejected:
            # Every address reaches the same device, so the answer holds for all of them.
            logger.warning("wireless.verify.rejected host=%s port=%s", host, port)
            mark_wireless_rejected(udid)
            raise RpcError(WIRELESS_REJECTED, f"The device no longer accepts its Wi-Fi pairing with "
                                              f"{identity.display_name()}; connect it with USB once to pair again") from None
        except (ConnectionTerminatedError, asyncio.IncompleteReadError, asyncio.TimeoutError, OSError):
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
