import asyncio
import http.client
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import AsyncMock, MagicMock, patch

from devicehubd.protocol import RpcError
from devicehubd.sandbox_mounts import ReadOnlyDAV, SandboxMounts, is_mounted, serve
from devicehubd.supervisor import Supervisor


class DAVGuardTests(unittest.IsolatedAsyncioTestCase):
    async def test_only_bounded_reads_with_mount_secret_reach_provider(self):
        app = AsyncMock()
        guarded = ReadOnlyDAV(app, "secret")
        cases = [
            ("/secret/Library", "GET", [], None),
            ("/secret/", "PROPFIND", [(b"depth", b"1")], None),
            ("/secret/", "HEAD", [], None),
            ("/secret", "OPTIONS", [], None),
            ("/", "GET", [], 404),
            ("/secret-other/", "GET", [], 404),
            ("/secret/../Library", "GET", [], 400),
            ("/secret/a\0", "GET", [], 400),
            ("/secret/", "PROPFIND", [], 403),
            ("/secret/", "PROPFIND", [(b"depth", b"infinity")], 403),
        ] + [("/secret/file", method, [], 403) for method in
             ["PUT", "DELETE", "MOVE", "COPY", "MKCOL", "LOCK", "UNLOCK", "PROPPATCH", "POST"]]
        for path, method, headers, status in cases:
            with self.subTest(path=path, method=method, headers=headers):
                app.reset_mock()
                send = AsyncMock()
                await guarded({"type": "http", "path": path, "method": method, "headers": headers}, AsyncMock(), send)
                if status is None:
                    app.assert_awaited_once()
                else:
                    app.assert_not_awaited()
                    self.assertEqual(send.call_args_list[0].args[0]["status"], status)


class ProviderTests(unittest.IsolatedAsyncioTestCase):
    async def test_nested_listing_range_reads_and_separate_mount_prefixes(self):
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root)
            (directory / "Library").mkdir()
            payload = b"0123456789abcdef" * 4096
            (directory / "Library" / "file with spaces.db").write_bytes(payload)
            afc = MagicMock()
            afc.os_stat = AsyncMock(side_effect=lambda p: (directory / p.lstrip("/")).stat())
            afc.listdir = AsyncMock(side_effect=lambda p: [x.name for x in (directory / p.lstrip("/")).iterdir()])
            afc.fopen = AsyncMock(side_effect=lambda p, mode: (directory / p.lstrip("/")).open("rb"))
            afc.fread = AsyncMock(side_effect=lambda f, size: f.read(size))
            afc.fseek = AsyncMock(side_effect=lambda f, offset, whence: f.seek(offset, whence))
            afc.fclose = AsyncMock(side_effect=lambda f: f.close())
            servers = []
            try:
                for token in ["first-secret", "second-secret"]:
                    servers.append(await serve(afc, token))

                def request(server, path, method="GET", headers=None):
                    conn = http.client.HTTPConnection("127.0.0.1", server.port, timeout=5)
                    try:
                        conn.request(method, path, headers=headers or {})
                        response = conn.getresponse()
                        return response.status, response.read(), {key.lower(): value for key, value in response.getheaders()}
                    finally:
                        conn.close()

                for server, token, other in [(servers[0], "first-secret", "second-secret"),
                                              (servers[1], "second-secret", "first-secret")]:
                    status, data, _ = await asyncio.to_thread(request, server, f"/{token}/Library/", "PROPFIND", {"Depth": "1"})
                    self.assertEqual(status, 207)
                    self.assertIn(b"file%20with%20spaces.db", data)
                    status, data, headers = await asyncio.to_thread(request, server, f"/{token}/Library/file%20with%20spaces.db", "GET", {"Range": "bytes=1024-2047"})
                    self.assertEqual(status, 206)
                    self.assertEqual(data, payload[1024:2048])
                    self.assertEqual(headers.get("content-range"), "bytes 1024-2047/65536")
                    status, _, _ = await asyncio.to_thread(request, server, f"/{other}/Library/")
                    self.assertEqual(status, 404)
                self.assertTrue(all(call.args[1] == "r" for call in afc.fopen.call_args_list))
            finally:
                for server in servers:
                    await server.stop()


class LifecycleTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.manager = SandboxMounts(object(), Path(self.tmp.name))
        self.afc = MagicMock(listdir=AsyncMock(return_value=[]), aclose=AsyncMock())
        self.server = MagicMock(port=12345, stop=AsyncMock())
        self.mounted = set()

        async def command(*args, **kwargs):
            if args[0].endswith("mount_webdav"):
                self.mounted.add(args[-1])
                self.assertIn("rdonly,nobrowse", args)
                self.assertIn("http://127.0.0.1:12345/", args[-2])
            else:
                self.mounted.discard(args[-1])
            return 0

        self.patches = [
            patch("devicehubd.sandbox_mounts.HouseArrestService.create", AsyncMock(return_value=self.afc)),
            patch("devicehubd.sandbox_mounts.serve", AsyncMock(return_value=self.server)),
            patch("devicehubd.sandbox_mounts.command", AsyncMock(side_effect=command)),
            patch("devicehubd.sandbox_mounts.is_mounted", AsyncMock(side_effect=lambda p: str(p) in self.mounted)),
        ]
        self.create, self.serve, self.command, _ = [p.start() for p in self.patches]

    async def asyncTearDown(self):
        await self.manager.close()
        for p in reversed(self.patches):
            p.stop()
        self.tmp.cleanup()

    async def test_reuses_volume_and_eject_releases_resources(self):
        one = await self.manager.mount("example", "Example")
        two = await self.manager.mount("example", "Example")
        self.assertEqual(one, two)
        self.create.assert_awaited_once()
        self.assertEqual(set(one), {"id", "bundleID", "path"})
        await self.manager.unmount(one["id"])
        self.assertFalse(self.manager.snapshot())
        self.assertFalse(self.mounted)
        self.server.stop.assert_awaited_once()
        self.afc.aclose.assert_awaited_once()
        self.assertFalse(Path(one["path"]).exists())

    async def test_access_denied_starts_no_listener(self):
        self.afc.listdir.side_effect = RuntimeError("denied")
        with self.assertRaises(RuntimeError):
            await self.manager.mount("example", "Example")
        self.serve.assert_not_awaited()
        self.afc.aclose.assert_awaited_once()
        self.assertFalse(list(Path(self.tmp.name).iterdir()))

    async def test_mount_failure_cleans_up(self):
        self.command.side_effect = None
        self.command.return_value = 1
        with self.assertRaises(RpcError):
            await self.manager.mount("example", "Example")
        self.server.stop.assert_awaited_once()
        self.afc.aclose.assert_awaited_once()
        self.assertFalse(list(Path(self.tmp.name).iterdir()))

    async def test_busy_volume_keeps_server_until_retry(self):
        volume = await self.manager.mount("example", "Example")
        self.command.side_effect = None
        self.command.return_value = 1
        with self.assertRaises(RpcError):
            await self.manager.unmount(volume["id"])
        self.assertEqual(self.manager.snapshot(), [volume])
        self.server.stop.assert_not_awaited()

    async def test_shutdown_cancels_pending_mount_and_closes_afc(self):
        pending = asyncio.Event()

        async def wait(*args):
            pending.set()
            await asyncio.Event().wait()

        self.serve.side_effect = wait
        task = asyncio.create_task(self.manager.mount("example", "Example"))
        await pending.wait()
        await self.manager.close()
        self.assertTrue(task.cancelled())
        self.afc.aclose.assert_awaited_once()
        self.assertFalse(self.manager.snapshot())

    async def test_shutdown_unmounts_before_stopping_server(self):
        volume = await self.manager.mount("example", "Example")
        async def stopped():
            self.assertFalse(self.mounted)
        self.server.stop.side_effect = stopped
        await self.manager.close()
        self.assertFalse(Path(volume["path"]).exists())
        with self.assertRaises(RpcError):
            await self.manager.mount("example", "Example")

    async def test_finder_eject_is_detected(self):
        await self.manager.mount("example", "Example")
        self.mounted.clear()
        async with asyncio.timeout(3):
            while self.manager.snapshot():
                await asyncio.sleep(0.05)
        self.server.stop.assert_awaited_once()
        self.afc.aclose.assert_awaited_once()


class RoutingTests(unittest.IsolatedAsyncioTestCase):
    async def test_list_and_eject_do_not_open_a_device_worker(self):
        supervisor = Supervisor.__new__(Supervisor)
        supervisor.workers = {}
        supervisor._ios_record = MagicMock()
        supervisor._worker = AsyncMock()
        self.assertEqual(await supervisor.dispatch("sandboxMounts", {"udid": "U"}, MagicMock()), {"mounts": []})
        await supervisor.dispatch("unmountSandbox", {"udid": "U", "token": "T"}, MagicMock())
        supervisor._worker.assert_not_awaited()

    async def test_mount_routes_to_existing_device_connection(self):
        supervisor = Supervisor.__new__(Supervisor)
        supervisor._ios_record = MagicMock()
        worker = MagicMock(call=AsyncMock(return_value={"path": "/volume"}))
        supervisor._worker = AsyncMock(return_value=worker)
        result = await supervisor.dispatch("mountSandbox", {"udid": "U", "bundleID": "app", "label": "App"}, MagicMock())
        self.assertEqual(result, {"path": "/volume"})
        worker.call.assert_awaited_once_with("mountSandbox", {"bundleID": "app", "label": "App"}, timeout=45)


@unittest.skipUnless(os.environ.get("DEVICEHUB_SANDBOX_DEVICE") and os.environ.get("DEVICEHUB_SANDBOX_APP")
                     and os.environ.get("DEVICEHUB_SANDBOX_FILE"), "Requires an explicitly selected physical device/app/file")
class DeviceMountIntegrationTests(unittest.IsolatedAsyncioTestCase):
    async def test_rsd_mount_read_and_unmount(self):
        from devicehubd.transports import make_tunnel
        tunnel = make_tunnel("usb", os.environ["DEVICEHUB_SANDBOX_DEVICE"])
        with tempfile.TemporaryDirectory(dir=".build") as root:
            manager = None
            try:
                rsd = await tunnel.open()
                manager = SandboxMounts(rsd, Path(root).resolve())
                volume = await manager.mount(os.environ["DEVICEHUB_SANDBOX_APP"], "Sandbox integration test")
                path = Path(volume["path"])
                self.assertTrue(await is_mounted(path))
                children = await asyncio.to_thread(lambda: [p.name for p in path.iterdir()])
                self.assertIn("Library", children)
                file = path / os.environ["DEVICEHUB_SANDBOX_FILE"]
                def read():
                    with file.open("rb") as stream:
                        return stream.read(16)
                self.assertTrue(await asyncio.to_thread(read))
                flags = await asyncio.to_thread(os.statvfs, path)
                self.assertTrue(flags.f_flag & os.ST_RDONLY)
                await manager.unmount(volume["id"])
                self.assertFalse(await is_mounted(path))
                self.assertFalse(path.exists())
            finally:
                if manager:
                    await manager.close()
                await tunnel.close()
