import asyncio
import ctypes
import socket
import unittest
from unittest.mock import patch

from devicehubd import system_bonjour


def sockaddr_in6(address, scope=0):
    raw = bytearray(28)
    raw[0], raw[1] = 28, socket.AF_INET6
    raw[8:24] = socket.inet_pton(socket.AF_INET6, address)
    raw[24:28] = scope.to_bytes(4, "little")
    return raw


class ParsingTests(unittest.TestCase):
    def test_txt_record_keeps_case_values_and_first_duplicate(self):
        data = b"\x0eidentifier=ABC\x0cauthTag=x=y/\x07flags=0\x08flags=99\x00\x04bare"
        self.assertEqual(system_bonjour.parse_txt(data),
                         {"identifier": "ABC", "authTag": "x=y/", "flags": "0", "bare": ""})

    def test_ipv4_and_kame_scoped_link_local_sockaddrs(self):
        v4 = bytearray(16)
        v4[0], v4[1] = 16, socket.AF_INET
        v4[4:8] = socket.inet_aton("192.168.1.101")
        buffer = (ctypes.c_char * 16).from_buffer(v4)
        self.assertEqual(system_bonjour.parse_sockaddr(ctypes.addressof(buffer)), "192.168.1.101")
        v6 = sockaddr_in6("fe80::c03:6fa:296e:cadb", 17)
        v6[10:12] = b"\x00\x11"  # scope embedded by the kernel
        buffer6 = (ctypes.c_char * 28).from_buffer(v6)
        self.assertEqual(system_bonjour.parse_sockaddr(ctypes.addressof(buffer6)), "fe80::c03:6fa:296e:cadb")


class FallbackTests(unittest.IsolatedAsyncioTestCase):
    async def test_raw_multicast_browse_is_used_without_dns_sd(self):
        async def raw(service_type, timeout):
            yield ("raw", service_type, timeout)

        with patch.object(system_bonjour, "available", return_value=False), \
                patch.object(system_bonjour, "iter_browse_service", raw):
            answers = [item async for item in system_bonjour.iter_browse("_x._tcp.local.", 1.5)]
        self.assertEqual(answers, [("raw", "_x._tcp.local.", 1.5)])


@unittest.skipUnless(system_bonjour.available(), "needs the macOS mDNSResponder")
class SystemBrowseTests(unittest.IsolatedAsyncioTestCase):
    async def test_browse_finds_a_locally_registered_service(self):
        # Registers through the same daemon (dns-sd -R) and expects the browse to resolve it.
        name = "phone-use-test-%d" % id(self)
        process = await asyncio.create_subprocess_exec(
            "dns-sd", "-R", name, "_phoneusetest._tcp", "local.", "4242", "k=v",
            stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL)
        try:
            found = None
            for _ in range(5):
                async for answer in system_bonjour.iter_browse("_phoneusetest._tcp.local.", 2.0):
                    if answer.instance.startswith(name):
                        found = answer
                        break
                if found:
                    break
            self.assertIsNotNone(found)
            self.assertEqual((found.port, found.properties), (4242, {"k": "v"}))
            self.assertTrue(found.addresses)
        finally:
            process.terminate()
            await process.wait()


if __name__ == "__main__":
    unittest.main()
