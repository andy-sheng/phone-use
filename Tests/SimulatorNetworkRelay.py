import asyncio
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import unittest

path = Path(__file__).resolve().parents[1] / "Sources/PhoneUseApp/Resources/phoneuse_network_debug.py"
spec = importlib.util.spec_from_file_location("network_debug", path)
network = importlib.util.module_from_spec(spec)
spec.loader.exec_module(network)


class RelayTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.relay = network.Relay(32)
        self.server = await asyncio.start_server(self.relay.handle, "127.0.0.1", 0)
        self.port = self.server.sockets[0].getsockname()[1]
        self.addAsyncCleanup(self.close_server, self.server)

    async def close_server(self, server):
        server.close()
        await server.wait_closed()

    async def client(self):
        reader, writer = await asyncio.open_connection("127.0.0.1", self.port)
        self.addCleanup(writer.close)
        return reader, writer

    async def authenticate(self, token):
        reader, writer = await self.client()
        writer.write(b"\x05\x01\x02")
        self.assertEqual(await reader.readexactly(2), b"\x05\x02")
        writer.write(b"\x01\x08phoneuse" + bytes([len(token)]) + token)
        return reader, writer

    async def test_requires_session_credentials(self):
        reader, writer = await self.client()
        writer.write(b"\x05\x01\x00")
        self.assertEqual(await reader.read(), b"\x05\xff")
        reader, _ = await self.authenticate(b"incorrect")
        self.assertEqual(await reader.read(), b"\x01\x01")

    async def test_authenticated_metrics_contain_only_disclosed_fields(self):
        fields = dict(event="request", url="https://user:password@example.com/a?q=secret#frag",
                      method="GET", millis=210, sent=11, received=55, status=200, body="secret")
        sink = io.StringIO()
        with contextlib.redirect_stdout(sink):
            for token in ("wrong", self.relay.token):
                reader, writer = await self.client()
                writer.write(json.dumps(dict(fields, token=token)).encode() + b"\n")
                self.assertEqual(await reader.read(), b"")
        self.assertEqual(json.loads(sink.getvalue()), dict(event="request", url="https://example.com/a",
                         method="GET", millis=210, sent=11, received=55, status=200))

    async def test_concurrent_connections_share_each_direction_and_support_half_close(self):
        async def echo(reader, writer):
            data = await reader.read()
            writer.write(data)
            await writer.drain()
            writer.close()
        origin = await asyncio.start_server(echo, "127.0.0.1", 0)
        self.addAsyncCleanup(self.close_server, origin)
        port = origin.sockets[0].getsockname()[1]

        async def transfer():
            reader, writer = await self.authenticate(self.relay.token.encode())
            self.assertEqual(await reader.readexactly(2), b"\x01\x00")
            writer.write(b"\x05\x01\x00\x01\x7f\x00\x00\x01" + port.to_bytes(2, "big"))
            self.assertEqual((await reader.readexactly(10))[:2], b"\x05\x00")
            writer.write(b"a" * 8192)
            writer.write_eof()
            self.assertEqual(await reader.read(), b"a" * 8192)

        start = asyncio.get_running_loop().time()
        async with asyncio.timeout(5):
            await asyncio.gather(transfer(), transfer())
        # Two serialized uploads (0.5 s) plus the last download (0.25 s).
        self.assertGreaterEqual(asyncio.get_running_loop().time() - start, .72)


if __name__ == "__main__":
    unittest.main()
