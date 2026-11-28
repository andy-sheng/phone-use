"""Live per-process connection list from a physical iPhone's packet capture service.

``com.apple.pcapd`` mirrors every packet the device sends or receives, and the kernel
tags each one with the owning process. This module folds packets into connections,
names them from DNS answers, TLS ClientHello SNI and plaintext HTTP request heads, and
keeps a bounded table that clients read incrementally by revision cursor.

HTTPS payloads stay encrypted: only the server name and transfer sizes are visible.
"""
import asyncio
import contextlib
import ipaddress
import logging
import secrets
import struct
import time
from collections import OrderedDict, deque
from typing import Any, Optional

from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.services.pcapd import PcapdService, parse_device_packet

from devicehubd.protocol import RpcError

logger = logging.getLogger("devicehubd.traffic")

# pcapd's ``io`` field: packets the device sent, and packets it received.
OUTGOING, INCOMING = 1, 16
TCP, UDP = 6, 17
FIN, SYN, RST, ACK = 0x01, 0x02, 0x04, 0x10
MAX_FLOWS = 2000
MAX_HOSTS = 4096
MAX_REQUESTS = 20
READ_BATCH = 300
HELLO_LIMIT = 16384
HTTP_HEAD_LIMIT = 8192
# Let worker RPCs run while a burst of buffered packets is parsed.
YIELD_EVERY = 256
HTTP_METHODS = tuple(m.encode() + b" " for m in
                     ("GET", "POST", "PUT", "HEAD", "DELETE", "PATCH", "OPTIONS", "CONNECT", "TRACE"))
ULA = ipaddress.ip_network("fc00::/7")
# Tri-state results for payload probes that may span several segments.
NEED_MORE = object()


class Segment:
    __slots__ = ("proto", "src", "dst", "sport", "dport", "flags", "payload", "size")

    def __init__(self, proto, src, dst, sport, dport, flags, payload, size):
        self.proto, self.src, self.dst = proto, src, dst
        self.sport, self.dport, self.flags = sport, dport, flags
        self.payload, self.size = payload, size


def parse_segment(data: bytes, offset: int) -> Optional[Segment]:
    """TCP or UDP segment of an IPv4/IPv6 packet that starts at ``offset``."""
    if len(data) <= offset:
        return None
    version = data[offset] >> 4
    if version == 4:
        if len(data) < offset + 20:
            return None
        ihl = (data[offset] & 15) * 4
        total, fragment = struct.unpack_from("!H2xH", data, offset + 2)
        if ihl < 20 or fragment & 0x1FFF:
            return None  # Later fragments carry no transport header.
        proto = data[offset + 9]
        src, dst = data[offset + 12:offset + 16], data[offset + 16:offset + 20]
        start = offset + ihl
        # Segmentation offload can leave the length at zero in captured outgoing packets.
        end = offset + total if total >= ihl else len(data)
    elif version == 6:
        if len(data) < offset + 40:
            return None
        payload_length, = struct.unpack_from("!H", data, offset + 4)
        proto = data[offset + 6]
        src, dst = data[offset + 8:offset + 24], data[offset + 24:offset + 40]
        start = offset + 40
        end = start + payload_length if payload_length else len(data)
    else:
        return None
    if proto == TCP:
        if len(data) < start + 20:
            return None
        sport, dport = struct.unpack_from("!HH", data, start)
        flags = data[start + 13]
        body = start + (data[start + 12] >> 4) * 4
    elif proto == UDP:
        if len(data) < start + 8:
            return None
        sport, dport = struct.unpack_from("!HH", data, start)
        flags = 0
        body = start + 8
    else:
        return None
    return Segment(proto, ipaddress.ip_address(bytes(src)), ipaddress.ip_address(bytes(dst)), sport, dport,
                   flags, bytes(data[body:min(end, len(data))]), max(0, end - body))


def is_device_link(src, dst) -> bool:
    """CoreDevice tunnels between this Mac and the phone, including this capture's own stream."""
    return src.version == 6 and src in ULA and dst in ULA and src.packed[:8] == dst.packed[:8]


def _dns_name(message: bytes, position: int) -> tuple[str, int]:
    labels, end, jumps = [], None, 0
    while True:
        size = message[position]
        if size & 0xC0 == 0xC0:
            jumps += 1
            if jumps > 16:
                raise ValueError("DNS compression loop")
            if end is None:
                end = position + 2
            position = ((size & 0x3F) << 8) | message[position + 1]
            continue
        position += 1
        if size == 0:
            break
        labels.append(message[position:position + size].decode("ascii", "replace"))
        position += size
    return ".".join(labels).lower(), end if end is not None else position


def dns_answers(message: bytes) -> Optional[tuple[str, list]]:
    """Question name and its A/AAAA addresses from a DNS response."""
    try:
        flags, questions, answers = struct.unpack_from("!HHH", message, 2)
        if not flags & 0x8000 or questions != 1:
            return None
        name, position = _dns_name(message, 12)
        position += 4
        addresses = []
        for _ in range(answers):
            _, position = _dns_name(message, position)
            kind, _, _, length = struct.unpack_from("!HHIH", message, position)
            position += 10
            record = message[position:position + length]
            position += length
            if (kind, length) in ((1, 4), (28, 16)) and len(record) == length:
                addresses.append(ipaddress.ip_address(record))
        return name, addresses
    except (struct.error, IndexError, ValueError):
        return None


def client_hello_server_name(data: bytes):
    """SNI of a TLS ClientHello: a name, ``""`` without SNI, None if not TLS, or NEED_MORE."""
    if len(data) < 6:
        return NEED_MORE if data[:1] in (b"", b"\x16") else None
    if data[0] != 0x16 or data[1] != 3 or data[5] != 1:
        return None
    length, = struct.unpack_from("!H", data, 3)
    if len(data) < 5 + length:
        return NEED_MORE if len(data) < HELLO_LIMIT else None
    hello = data[5:5 + length]
    try:
        position = 4 + 2 + 32
        position += 1 + hello[position]
        position += 2 + struct.unpack_from("!H", hello, position)[0]
        position += 1 + hello[position]
        end = position + 2 + struct.unpack_from("!H", hello, position)[0]
        position += 2
        while position + 4 <= min(end, len(hello)):
            kind, size = struct.unpack_from("!HH", hello, position)
            position += 4
            if kind == 0:
                # server_name_list: length, then entries of (type, length, name).
                if hello[position + 2] == 0:
                    name_length, = struct.unpack_from("!H", hello, position + 3)
                    return hello[position + 5:position + 5 + name_length].decode("ascii", "replace").lower()
                return ""
            position += size
    except (struct.error, IndexError):
        return None
    return ""


def http_request_head(data: bytes):
    """(method, target, host) of an HTTP/1 request head, None if not HTTP, or NEED_MORE."""
    if not data.startswith(HTTP_METHODS):
        return None
    end = data.find(b"\r\n\r\n")
    if end < 0:
        return NEED_MORE if len(data) < HTTP_HEAD_LIMIT else None
    lines = data[:end].decode("latin-1").split("\r\n")
    parts = lines[0].split(" ")
    if len(parts) != 3 or not parts[2].startswith("HTTP/1."):
        return None
    host = next((line.split(":", 1)[1].strip() for line in lines[1:]
                 if line.lower().startswith("host:")), "")
    return parts[0], parts[1], host


def http_response_status(data: bytes) -> Optional[int]:
    if not data.startswith(b"HTTP/1.") or len(data) < 12 or not data[9:12].isdigit():
        return None
    return int(data[9:12])


class Flow:
    __slots__ = ("id", "rev", "proto", "local", "lport", "remote", "rport", "interface", "process", "pid",
                 "app", "host", "kind", "first", "last", "sent", "received", "packets", "closed", "requests",
                 "probe")

    def __init__(self, ident, proto, local, lport, remote, rport, interface, now):
        self.id, self.rev, self.proto = ident, 0, proto
        self.local, self.lport, self.remote, self.rport = local, lport, remote, rport
        self.interface = interface
        self.process, self.pid, self.app, self.host = "", 0, None, None
        self.kind = "dns" if rport == 53 else "quic" if proto == UDP and rport == 443 else (
            "tcp" if proto == TCP else "udp")
        self.first = self.last = now
        self.sent = self.received = self.packets = 0
        self.closed = False
        self.requests: deque = deque(maxlen=MAX_REQUESTS)
        # Buffered client bytes until a TLS ClientHello or HTTP head is recognised.
        self.probe: Optional[bytearray] = bytearray() if proto == TCP else None

    def to_json(self) -> dict[str, Any]:
        return {"id": self.id, "process": self.process, "pid": self.pid, "app": self.app,
                "interface": self.interface, "protocol": "tcp" if self.proto == TCP else "udp",
                "kind": self.kind, "host": self.host, "remote": str(self.remote), "remotePort": self.rport,
                "localPort": self.lport, "firstSeen": self.first, "lastSeen": self.last, "sent": self.sent,
                "received": self.received, "packets": self.packets, "closed": self.closed,
                "requests": list(self.requests)}


class FlowTable:
    def __init__(self) -> None:
        self.flows: OrderedDict[tuple, Flow] = OrderedDict()
        self.hosts: OrderedDict[Any, str] = OrderedDict()
        self.revision = 0
        self.next_id = 0

    def add(self, packet: Any, now: float) -> None:
        if packet.interface_name.startswith("lo"):
            return
        segment = parse_segment(packet.data, packet.frame_pre_length)
        if segment is None or is_device_link(segment.src, segment.dst):
            return
        if packet.io == OUTGOING:
            outgoing = True
            key = (segment.proto, segment.src, segment.sport, segment.dst, segment.dport)
        elif packet.io == INCOMING:
            outgoing = False
            key = (segment.proto, segment.dst, segment.dport, segment.src, segment.sport)
        else:
            return
        if not outgoing and segment.proto == UDP and segment.sport in (53, 5353):
            self._learn(segment.payload)
        flow = self.flows.get(key)
        opening = segment.proto == TCP and segment.flags & (SYN | ACK) == SYN
        if flow is None or (flow.closed and opening):
            if flow is not None:
                del self.flows[key]
            self.next_id += 1
            flow = Flow(self.next_id, *key, packet.interface_name, now)
            flow.host = self.hosts.get(flow.remote)
            self.flows[key] = flow
            while len(self.flows) > MAX_FLOWS:
                self.flows.popitem(last=False)
        else:
            self.flows.move_to_end(key)
        if packet.pid and (outgoing or not flow.pid):
            flow.process, flow.pid = packet.comm, packet.pid
            flow.app = packet.ecomm if packet.epid and packet.epid != packet.pid and packet.ecomm else None
        flow.last = now
        flow.packets += 1
        if outgoing:
            flow.sent += segment.size
        else:
            flow.received += segment.size
        if segment.proto == TCP and segment.flags & (FIN | RST):
            flow.closed = True
        if segment.payload:
            self._inspect(flow, segment.payload, outgoing)
        self.revision += 1
        flow.rev = self.revision

    def _learn(self, message: bytes) -> None:
        answer = dns_answers(message)
        if not answer:
            return
        name, addresses = answer
        for address in addresses:
            self.hosts[address] = name
            self.hosts.move_to_end(address)
        while len(self.hosts) > MAX_HOSTS:
            self.hosts.popitem(last=False)

    def _inspect(self, flow: Flow, payload: bytes, outgoing: bool) -> None:
        if flow.kind == "dns" and outgoing:
            with contextlib.suppress(struct.error, IndexError, ValueError):
                flow.host = _dns_name(payload, 12)[0] or flow.host
            return
        if flow.proto != TCP:
            return
        if not outgoing:
            status = http_response_status(payload)
            if status is not None and status >= 200:
                pending = next((r for r in flow.requests if r["status"] is None), None)
                if pending is not None:
                    pending["status"] = status
            return
        if flow.probe is None:
            if flow.kind != "http" or not payload.startswith(HTTP_METHODS):
                return
            flow.probe = bytearray()  # A keep-alive connection's next request.
        flow.probe += payload
        data = bytes(flow.probe)
        if flow.kind != "http":
            name = client_hello_server_name(data)
            if name is NEED_MORE:
                return
            if name is not None:
                flow.kind = "tls"
                flow.host = name or flow.host
                flow.probe = None
                return
        head = http_request_head(data)
        if head is NEED_MORE:
            return
        flow.probe = None
        if head is None:
            return
        method, target, host = head
        flow.kind = "http"
        flow.host = host.rsplit(":", 1)[0] if host and not host.startswith("[") else host or flow.host
        if not target.startswith(("http://", "https://")):
            authority = host or (flow.host or str(flow.remote))
            target = f"http://{authority}{target if target.startswith('/') else '/' + target}"
        flow.requests.append({"method": method, "url": target[:2048], "status": None})

    def read(self, after: int) -> dict[str, Any]:
        rows = sorted((f for f in self.flows.values() if f.rev > after), key=lambda f: f.rev)
        batch = rows[:READ_BATCH]
        more = len(rows) > READ_BATCH
        return {"flows": [f.to_json() for f in batch],
                "nextCursor": batch[-1].rev if more else self.revision, "hasMore": more}


class TrafficCapture:
    """One capture per device worker. Flows stay readable after the capture stops."""

    def __init__(self, udid: str) -> None:
        self.udid = udid
        self.table = FlowTable()
        self.session = secrets.token_hex(8)
        self.task: Optional[asyncio.Task[None]] = None
        self.error: Optional[str] = None
        self.packets = 0
        self.lock = asyncio.Lock()

    async def command(self, params: dict[str, Any]) -> dict[str, Any]:
        action = params.get("action")
        after = params.get("after", 0)
        if action not in ("start", "stop", "clear", "read"):
            raise RpcError("invalidParams", "Unknown traffic capture action")
        if type(after) is not int or after < 0:
            raise RpcError("invalidParams", "Invalid traffic cursor")
        async with self.lock:
            if action == "start":
                await self._start()
                after = 0
            elif action == "stop":
                await self._stop()
            elif action == "clear":
                self._reset()
                after = 0
        return self.read(after)

    def read(self, after: int) -> dict[str, Any]:
        if after > self.table.revision:
            after = 0  # A cursor from a previous table.
        return {"session": self.session, "running": self.running, "error": self.error,
                "packets": self.packets, **self.table.read(after)}

    @property
    def running(self) -> bool:
        return self.task is not None and not self.task.done()

    def _reset(self) -> None:
        self.table = FlowTable()
        self.session = secrets.token_hex(8)
        self.packets = 0

    async def _open(self) -> tuple[Any, PcapdService]:
        # RemoteXPC refuses pcapd, and Wi-Fi lockdown would mirror its own stream back
        # into the capture. A USB lockdown link is outside the device's IP interfaces.
        try:
            lockdown = await asyncio.wait_for(
                create_using_usbmux(serial=self.udid, autopair=False, connection_type="USB"), 15)
        except Exception as error:
            raise RpcError("needsUsb", "实时抓包需要用 USB 线连接这台设备") from error
        service = PcapdService(lockdown)
        try:
            await asyncio.wait_for(service.connect(), 15)
        except Exception as error:
            with contextlib.suppress(Exception):
                await lockdown.close()
            raise RpcError("captureUnavailable", f"设备未提供抓包服务：{error}") from error
        return lockdown, service

    async def _start(self) -> None:
        if self.running:
            return
        lockdown, service = await self._open()
        self._reset()
        self.error = None
        self.task = asyncio.create_task(self._run(lockdown, service))

    async def _run(self, lockdown: Any, service: PcapdService) -> None:
        try:
            while True:
                message = await service.service.recv_plist()
                if not message:
                    self.error = "设备结束了抓包"
                    return
                self.packets += 1
                try:
                    self.table.add(parse_device_packet(message), time.time())
                except Exception:
                    logger.debug("skipped an unparsable packet", exc_info=True)
                if self.packets % YIELD_EVERY == 0:
                    await asyncio.sleep(0)
        except asyncio.CancelledError:
            raise
        except Exception as error:
            logger.warning("traffic capture ended: %s", error)
            self.error = f"抓包已中断：{error}"
        finally:
            with contextlib.suppress(Exception):
                await service.close()
            with contextlib.suppress(Exception):
                await lockdown.close()

    async def _stop(self) -> None:
        task = self.task
        if task is not None and not task.done():
            task.cancel()
            with contextlib.suppress(BaseException):
                await task

    async def close(self) -> None:
        async with self.lock:
            await self._stop()
