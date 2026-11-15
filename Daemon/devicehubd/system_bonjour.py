"""Bonjour browsing through the system mDNSResponder (``dns_sd``) instead of raw multicast sockets.

pymobiledevice3 browses by binding UDP 5353 itself and sending to 224.0.0.251 / ff02::fb. When a
VPN or TUN proxy owns the default route, those queries leave through the tunnel and the devices'
answers never arrive, so Wi-Fi devices look absent or come and go. mDNSResponder queries every
interface itself, shares the system cache (including Sleep Proxy answers for sleeping devices),
and is what usbmuxd and CoreDevice rely on. The raw browse remains the fallback where ``dns_sd``
cannot be loaded.

Callbacks run inside ``DNSServiceProcessResult`` on the event loop thread (via ``add_reader``),
so no locking is needed.
"""

import asyncio
import contextlib
import ctypes
import logging
import socket
import sys
from collections.abc import AsyncIterator
from typing import Any, Callable, Optional

from pymobiledevice3.bonjour import Address, ServiceInstance, iter_browse_service

logger = logging.getLogger("devicehubd")

_FLAGS_MORE_COMING = 0x1
_FLAGS_ADD = 0x2
_PROTOCOL_IPV4 = 0x1
_PROTOCOL_IPV6 = 0x2
# After the last address answer without MoreComing, wait this long for the other address family.
_ADDRESS_SETTLE = 0.25
RESOLVE_TIMEOUT = 2.0

_BrowseReply = ctypes.CFUNCTYPE(
    None, ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_int32,
    ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p,
)
_ResolveReply = ctypes.CFUNCTYPE(
    None, ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_int32,
    ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint16, ctypes.c_uint16, ctypes.c_void_p, ctypes.c_void_p,
)
_AddrInfoReply = ctypes.CFUNCTYPE(
    None, ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_int32,
    ctypes.c_char_p, ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p,
)

_library: Optional[ctypes.CDLL] = None
_library_error: Optional[OSError] = None


def _dns_sd() -> ctypes.CDLL:
    global _library, _library_error
    if _library is not None:
        return _library
    if _library_error is not None:
        raise _library_error
    try:
        if sys.platform != "darwin":
            raise OSError("dns_sd is only used on macOS")
        lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
        ref = ctypes.POINTER(ctypes.c_void_p)
        lib.DNSServiceBrowse.argtypes = [ref, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_char_p,
                                         ctypes.c_char_p, _BrowseReply, ctypes.c_void_p]
        lib.DNSServiceResolve.argtypes = [ref, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_char_p,
                                          ctypes.c_char_p, ctypes.c_char_p, _ResolveReply, ctypes.c_void_p]
        lib.DNSServiceGetAddrInfo.argtypes = [ref, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32,
                                              ctypes.c_char_p, _AddrInfoReply, ctypes.c_void_p]
        for name in ("DNSServiceBrowse", "DNSServiceResolve", "DNSServiceGetAddrInfo", "DNSServiceProcessResult"):
            getattr(lib, name).restype = ctypes.c_int32
        lib.DNSServiceProcessResult.argtypes = [ctypes.c_void_p]
        lib.DNSServiceRefSockFD.argtypes = [ctypes.c_void_p]
        lib.DNSServiceRefSockFD.restype = ctypes.c_int
        lib.DNSServiceRefDeallocate.argtypes = [ctypes.c_void_p]
        lib.DNSServiceRefDeallocate.restype = None
    except (OSError, AttributeError) as error:
        _library_error = error if isinstance(error, OSError) else OSError(str(error))
        raise _library_error from error
    _library = lib
    return lib


def available() -> bool:
    try:
        _dns_sd()
    except OSError:
        return False
    return True


class _Operation:
    """One DNSServiceRef serviced by the running loop until closed."""

    def __init__(self, start: Callable[[Any], int], callback: Any) -> None:
        self._lib = _dns_sd()
        self._callback = callback  # ctypes callbacks must outlive the ref
        self._ref = ctypes.c_void_p()
        error = start(ctypes.byref(self._ref))
        if error:
            raise OSError(f"dns_sd request failed: {error}")
        self._loop = asyncio.get_running_loop()
        self._fd = self._lib.DNSServiceRefSockFD(self._ref)
        self._loop.add_reader(self._fd, self._process)

    def _process(self) -> None:
        if self._ref and self._lib.DNSServiceProcessResult(self._ref):
            # The daemon connection broke; stop polling a dead descriptor.
            self._loop.remove_reader(self._fd)

    def close(self) -> None:
        if self._ref:
            self._loop.remove_reader(self._fd)
            self._lib.DNSServiceRefDeallocate(self._ref)
            self._ref = ctypes.c_void_p()


def parse_txt(data: bytes) -> dict[str, str]:
    properties: dict[str, str] = {}
    offset = 0
    while offset < len(data):
        length = data[offset]
        entry = data[offset + 1:offset + 1 + length]
        offset += 1 + length
        key, _, value = entry.partition(b"=")
        if key:
            properties.setdefault(key.decode(errors="replace"), value.decode(errors="replace"))
    return properties


def parse_sockaddr(pointer: int) -> Optional[str]:
    family = ctypes.string_at(pointer, 2)[1]
    if family == socket.AF_INET:
        return socket.inet_ntop(socket.AF_INET, ctypes.string_at(pointer, 8)[4:8])
    if family == socket.AF_INET6:
        raw = bytearray(ctypes.string_at(pointer, 24)[8:24])
        if raw[0] == 0xFE and raw[1] & 0xC0 == 0x80:
            raw[2:4] = b"\0\0"  # KAME embeds the scope here; the interface name carries it instead
        return socket.inet_ntop(socket.AF_INET6, bytes(raw))
    return None


def _interface_name(index: int) -> str:
    with contextlib.suppress(OSError):
        return socket.if_indextoname(index)
    return ""


async def _resolve(interface: int, name: bytes, regtype: bytes, domain: bytes,
                   timeout: float, addresses: bool) -> Optional[ServiceInstance]:
    loop = asyncio.get_running_loop()
    resolved: asyncio.Future[tuple[str, str, int, dict[str, str]]] = loop.create_future()

    def on_resolve(_ref, _flags, _interface, error, fullname, host, port, txt_length, txt, _context):
        if resolved.done():
            return
        if error:
            resolved.set_exception(OSError(f"resolve failed: {error}"))
            return
        resolved.set_result((
            (fullname or b"").decode(errors="replace"), (host or b"").decode(errors="replace"),
            socket.ntohs(port), parse_txt(ctypes.string_at(txt, txt_length) if txt else b""),
        ))

    callback = _ResolveReply(on_resolve)
    operation = _Operation(
        lambda ref: _dns_sd().DNSServiceResolve(ref, 0, interface, name, regtype, domain, callback, None), callback)
    try:
        fullname, host, port, properties = await asyncio.wait_for(resolved, timeout)
    except (asyncio.TimeoutError, OSError) as error:
        logger.debug("Bonjour resolve of %r failed: %r", name, error)
        return None
    finally:
        operation.close()
    instance = ServiceInstance(instance=fullname, host=host.rstrip(".") or None, port=port, properties=properties)
    if addresses and host:
        instance.addresses = await _addresses(host, interface, timeout)
    return instance


async def _addresses(host: str, interface: int, timeout: float) -> list[Address]:
    loop = asyncio.get_running_loop()
    found: list[str] = []
    settled = asyncio.Event()
    settle_handle: list[asyncio.TimerHandle] = []

    def on_address(_ref, flags, _interface, error, _host, address, _ttl, _context):
        if error or not address or not flags & _FLAGS_ADD:
            return
        ip = parse_sockaddr(address)
        if ip and ip not in found:
            found.append(ip)
        if not flags & _FLAGS_MORE_COMING and not settle_handle:
            settle_handle.append(loop.call_later(_ADDRESS_SETTLE, settled.set))

    callback = _AddrInfoReply(on_address)
    operation = _Operation(lambda ref: _dns_sd().DNSServiceGetAddrInfo(
        ref, 0, interface, _PROTOCOL_IPV4 | _PROTOCOL_IPV6, host.encode(), callback, None), callback)
    try:
        with contextlib.suppress(asyncio.TimeoutError):
            await asyncio.wait_for(settled.wait(), timeout)
    finally:
        operation.close()
        for handle in settle_handle:
            handle.cancel()
    iface = _interface_name(interface)
    # IPv4 first: an asleep iPhone answered on IPv4 at once while its link-local IPv6 timed
    # out. Link-local next, since it is pinned to the interface and a VPN cannot capture it.
    found.sort(key=lambda ip: 0 if ":" not in ip else 1 if ip.lower().startswith("fe80:") else 2)
    return [Address(ip=ip, iface=iface) for ip in found]


async def _iter_system(service_type: str, timeout: float, addresses: bool) -> AsyncIterator[ServiceInstance]:
    loop = asyncio.get_running_loop()
    queue: asyncio.Queue[Any] = asyncio.Queue()

    def on_browse(_ref, flags, interface, error, name, regtype, domain, _context):
        if error:
            queue.put_nowait(OSError(f"browse failed: {error}"))
        elif flags & _FLAGS_ADD:
            queue.put_nowait((interface, name, regtype, domain))

    callback = _BrowseReply(on_browse)
    operation = _Operation(lambda ref: _dns_sd().DNSServiceBrowse(
        ref, 0, 0, service_type.rstrip(".").removesuffix(".local").encode(), b"local.", callback, None), callback)
    deadline = loop.time() + timeout
    handled: set[Any] = set()
    try:
        while (remaining := deadline - loop.time()) > 0:
            try:
                item = await asyncio.wait_for(queue.get(), remaining)
            except asyncio.TimeoutError:
                break
            if isinstance(item, Exception):
                raise item
            if item in handled:
                continue
            handled.add(item)
            instance = await _resolve(*item, timeout=min(RESOLVE_TIMEOUT, max(remaining, 0.5)), addresses=addresses)
            if instance is not None:
                yield instance
    finally:
        operation.close()


async def iter_browse(service_type: str, timeout: float, addresses: bool = True) -> AsyncIterator[ServiceInstance]:
    """Yield resolved instances of ``service_type`` seen within ``timeout`` seconds.

    With ``addresses=False`` only the TXT record and port are resolved, which is enough to
    recognise a device. Falls back to pymobiledevice3's raw multicast browse without ``dns_sd``.
    """
    if available():
        async with contextlib.aclosing(_iter_system(service_type, timeout, addresses)) as answers:
            async for answer in answers:
                yield answer
        return
    async with contextlib.aclosing(iter_browse_service(service_type, timeout=timeout)) as answers:
        async for answer in answers:
            yield answer


__all__ = ["available", "iter_browse", "parse_sockaddr", "parse_txt"]
