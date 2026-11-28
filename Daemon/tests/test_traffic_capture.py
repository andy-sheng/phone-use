import asyncio
import ipaddress
import struct
import unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

from devicehubd import traffic_capture
from devicehubd.protocol import RpcError
from devicehubd.traffic_capture import (INCOMING, OUTGOING, FlowTable, TrafficCapture, client_hello_server_name,
                                        dns_answers)

PHONE = "192.168.1.20"
SERVER = "93.184.216.34"
ACK, SYN, FIN, PSH = 0x10, 0x02, 0x01, 0x08


def ipv4(src, dst, proto, transport):
    header = struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + len(transport), 0, 0, 64, proto, 0,
                         ipaddress.ip_address(src).packed, ipaddress.ip_address(dst).packed)
    return header + transport


def ipv6(src, dst, proto, transport):
    header = struct.pack("!IHBB16s16s", 6 << 28, len(transport), proto, 64,
                         ipaddress.ip_address(src).packed, ipaddress.ip_address(dst).packed)
    return header + transport


def tcp(sport, dport, flags, payload=b""):
    return struct.pack("!HHIIBBHHH", sport, dport, 0, 0, 5 << 4, flags, 65535, 0, 0) + payload


def udp(sport, dport, payload):
    return struct.pack("!HHHH", sport, dport, 8 + len(payload), 0) + payload


def packet(io, data, interface="en", pre=14, comm="Shop", pid=501, ecomm="", epid=0):
    link = {14: b"\x00" * 12 + b"\x08\x00", 4: b"\x02\x00\x00\x00", 0: b""}[pre]
    return SimpleNamespace(io=io, data=link + data, interface_name=interface, frame_pre_length=pre,
                           comm=comm, pid=pid, ecomm=ecomm, epid=epid)


def dns_response(name, address):
    question = b"".join(bytes([len(p)]) + p.encode() for p in name.split(".")) + b"\x00"
    answer = b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 60, 4) + ipaddress.ip_address(address).packed
    return struct.pack("!HHHHHH", 7, 0x8180, 1, 1, 0, 0) + question + struct.pack("!HH", 1, 1) + answer


def client_hello(name, padding=1400):
    entry = b"\x00" + struct.pack("!H", len(name)) + name.encode()
    server_name = struct.pack("!H", len(entry)) + entry
    extensions = (struct.pack("!HH", 21, padding) + b"\x00" * padding +
                  struct.pack("!HH", 0, len(server_name)) + server_name)
    body = (b"\x03\x03" + b"\x11" * 32 + b"\x00" + b"\x00\x02\x13\x01" + b"\x01\x00" +
            struct.pack("!H", len(extensions)) + extensions)
    handshake = b"\x01" + struct.pack("!I", len(body))[1:] + body
    return b"\x16\x03\x01" + struct.pack("!H", len(handshake)) + handshake


class ParserTests(unittest.TestCase):
    def test_dns_and_client_hello(self):
        self.assertEqual(dns_answers(dns_response("api.example.com", SERVER)),
                         ("api.example.com", [ipaddress.ip_address(SERVER)]))
        hello = client_hello("Api.Example.com")
        self.assertEqual(client_hello_server_name(hello), "api.example.com")
        self.assertIs(client_hello_server_name(hello[:900]), traffic_capture.NEED_MORE)
        self.assertIsNone(client_hello_server_name(b"\x17\x03\x03\x00\x10" + b"\x00" * 16))


class FlowTableTests(unittest.TestCase):
    def setUp(self):
        self.table = FlowTable()

    def add(self, *args, **kwargs):
        self.table.add(packet(*args, **kwargs), 100.0)

    def flows(self):
        return self.table.read(0)["flows"]

    def test_dns_name_process_and_byte_counts(self):
        self.add(INCOMING, ipv4("8.8.8.8", PHONE, 17, udp(53, 5000, dns_response("api.example.com", SERVER))),
                 comm="mDNSResponder", pid=80)
        self.add(OUTGOING, ipv4(PHONE, SERVER, 6, tcp(52000, 443, SYN)), comm="nsurlsessiond", pid=90,
                 ecomm="Shop", epid=501)
        self.add(INCOMING, ipv4(SERVER, PHONE, 6, tcp(443, 52000, ACK, b"x" * 300)), comm="", pid=0)
        self.add(OUTGOING, ipv4(PHONE, SERVER, 6, tcp(52000, 443, ACK | PSH, b"y" * 40)), comm="nsurlsessiond",
                 pid=90, ecomm="Shop", epid=501)
        flow = next(f for f in self.flows() if f["remotePort"] == 443)
        self.assertEqual((flow["host"], flow["process"], flow["app"]), ("api.example.com", "nsurlsessiond", "Shop"))
        self.assertEqual((flow["sent"], flow["received"], flow["packets"]), (40, 300, 3))
        self.assertEqual((flow["kind"], flow["closed"]), ("tcp", False))
        self.assertEqual(sum(f["kind"] == "dns" for f in self.flows()), 1)

    def test_split_client_hello_names_tls_connection(self):
        hello = client_hello("cdn.example.net")
        for part in (hello[:1000], hello[1000:]):
            self.add(OUTGOING, ipv6("2001:db8::2", "2001:db8::1", 6, tcp(52001, 443, ACK | PSH, part)),
                     interface="utun", pre=4)
        flow, = self.flows()
        self.assertEqual((flow["kind"], flow["host"], flow["interface"]), ("tls", "cdn.example.net", "utun"))

    def test_http_requests_responses_and_keep_alive(self):
        def request(path):
            return f"GET {path} HTTP/1.1\r\nHost: plain.example.org:8080\r\nAccept: */*\r\n\r\n".encode()
        self.add(OUTGOING, ipv4(PHONE, SERVER, 6, tcp(52002, 8080, ACK | PSH, request("/a?x=1"))))
        self.add(INCOMING, ipv4(SERVER, PHONE, 6, tcp(8080, 52002, ACK, b"HTTP/1.1 100 Continue\r\n\r\n")))
        self.add(INCOMING, ipv4(SERVER, PHONE, 6, tcp(8080, 52002, ACK, b"HTTP/1.1 404 Not Found\r\n\r\n")))
        self.add(OUTGOING, ipv4(PHONE, SERVER, 6, tcp(52002, 8080, ACK | PSH, request("/b"))))
        flow, = self.flows()
        self.assertEqual((flow["kind"], flow["host"]), ("http", "plain.example.org"))
        self.assertEqual(flow["requests"], [
            {"method": "GET", "url": "http://plain.example.org:8080/a?x=1", "status": 404},
            {"method": "GET", "url": "http://plain.example.org:8080/b", "status": None}])

    def test_device_tunnel_and_loopback_are_ignored(self):
        self.add(OUTGOING, ipv6("fd51:91ff:e68b::1", "fd51:91ff:e68b::2", 6, tcp(62078, 50000, ACK, b"z")),
                 interface="utun", pre=4)
        self.add(OUTGOING, ipv4("127.0.0.1", "127.0.0.1", 6, tcp(1, 2, SYN)), interface="lo", pre=4)
        self.assertEqual(self.flows(), [])

    def test_cursor_returns_changed_flows_and_port_reuse_starts_new_flow(self):
        self.add(OUTGOING, ipv4(PHONE, SERVER, 6, tcp(52003, 443, SYN)))
        self.add(OUTGOING, ipv4(PHONE, "1.1.1.1", 6, tcp(52004, 443, SYN)))
        cursor = self.table.read(0)["nextCursor"]
        self.assertEqual(self.table.read(cursor)["flows"], [])
        self.add(INCOMING, ipv4(SERVER, PHONE, 6, tcp(443, 52003, FIN | ACK)))
        changed = self.table.read(cursor)
        self.assertEqual([f["remote"] for f in changed["flows"]], [SERVER])
        self.assertTrue(changed["flows"][0]["closed"])
        first_id = changed["flows"][0]["id"]
        self.add(OUTGOING, ipv4(PHONE, SERVER, 6, tcp(52003, 443, SYN)))
        newest = self.table.read(changed["nextCursor"])["flows"][0]
        self.assertNotEqual(newest["id"], first_id)
        self.assertFalse(newest["closed"])

    def test_read_batches(self):
        for port in range(traffic_capture.READ_BATCH + 5):
            self.add(OUTGOING, ipv4(PHONE, SERVER, 17, udp(10000 + port, 9999, b"q")))
        first = self.table.read(0)
        self.assertTrue(first["hasMore"])
        self.assertEqual(len(first["flows"]), traffic_capture.READ_BATCH)
        rest = self.table.read(first["nextCursor"])
        self.assertEqual((len(rest["flows"]), rest["hasMore"]), (5, False))


class TrafficCaptureTests(unittest.IsolatedAsyncioTestCase):
    async def test_start_stream_stop_keeps_flows(self):
        queue: asyncio.Queue = asyncio.Queue()
        service = SimpleNamespace(service=SimpleNamespace(recv_plist=queue.get), close=AsyncMock())
        lockdown = SimpleNamespace(close=AsyncMock())
        capture = TrafficCapture("udid")
        with patch.object(capture, "_open", AsyncMock(return_value=(lockdown, service))), \
                patch.object(traffic_capture, "parse_device_packet", side_effect=lambda value: value):
            started = await capture.command({"action": "start"})
            self.assertTrue(started["running"])
            await queue.put(packet(OUTGOING, ipv4(PHONE, SERVER, 6, tcp(52005, 443, SYN))))
            for _ in range(50):
                state = await capture.command({"action": "read", "after": 0})
                if state["flows"]:
                    break
                await asyncio.sleep(0.01)
            self.assertEqual(state["packets"], 1)
            self.assertEqual(state["flows"][0]["remote"], SERVER)
            stopped = await capture.command({"action": "stop"})
            self.assertFalse(stopped["running"])
            self.assertEqual(len(stopped["flows"]), 1)
            service.close.assert_awaited()
            lockdown.close.assert_awaited()
            cleared = await capture.command({"action": "clear"})
            self.assertNotEqual(cleared["session"], started["session"])
            self.assertEqual(cleared["flows"], [])

    async def test_ended_stream_reports_error_and_bad_params(self):
        service = SimpleNamespace(service=SimpleNamespace(recv_plist=AsyncMock(return_value=None)), close=AsyncMock())
        capture = TrafficCapture("udid")
        with patch.object(capture, "_open", AsyncMock(return_value=(SimpleNamespace(close=AsyncMock()), service))):
            await capture.command({"action": "start"})
            await asyncio.sleep(0.01)
            state = await capture.command({"action": "read"})
        self.assertFalse(state["running"])
        self.assertEqual(state["error"], "设备结束了抓包")
        for params in ({"action": "sniff"}, {"action": "read", "after": -1}, {"action": "read", "after": "1"}):
            with self.assertRaises(RpcError):
                await capture.command(params)


if __name__ == "__main__":
    unittest.main()
