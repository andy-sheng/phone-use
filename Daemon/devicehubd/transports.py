"""How devices are found and how a tunnel to them is built, one implementation per link type.

Only USB exists today. A network transport plugs in by adding a `Discovery` that reports
``connection="network"`` devices and a `Tunnel` that reaches them (RemotePairing over Bonjour);
the supervisor, the worker and the Swift client only ever see the ``connection`` string.
"""

from dataclasses import dataclass
from typing import Optional, Protocol

from pymobiledevice3.lockdown import UsbmuxLockdownClient, create_using_usbmux
from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService
from pymobiledevice3.remote.userspace_tunnel import UserspaceRsdTunnel
from pymobiledevice3.usbmux import list_devices

USB = "usb"


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


DISCOVERIES: list[Discovery] = [UsbDiscovery()]


def discovery_for(connection: str) -> Discovery:
    for discovery in DISCOVERIES:
        if discovery.connection == connection:
            return discovery
    raise ValueError(f"unsupported connection type: {connection}")


def make_tunnel(connection: str, udid: str) -> Tunnel:
    if connection == USB:
        return UsbTunnel(udid)
    raise ValueError(f"unsupported connection type: {connection}")
