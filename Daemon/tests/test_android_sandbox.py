import asyncio
import base64
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock

from devicehubd import android_sandbox as sandbox
from devicehubd.protocol import RpcError
from devicehubd.supervisor import Supervisor


class LocalADB:
    """Replay the actual remote quoting and shell programs against a temporary app directory."""

    def __init__(self, folder):
        self.root = folder / "data"
        self.root.mkdir()
        tools = folder / "bin"
        tools.mkdir()
        self.env = dict(os.environ, PATH=str(tools) + os.pathsep + os.defpath)
        self.script(tools / "am", 'echo 10')
        self.script(tools / "pm", '''printf 'package:example.debug versionCode:7\npackage:example.release versionCode:8\n' ''')
        self.script(tools / "run-as", '''
[ "$1" = example.debug ] && [ "$2" = --user ] && [ "$3" = 10 ] || exit 1
shift 3
case "$1" in /system/bin/true) exit 0;; /system/bin/sh) shift; exec /bin/sh "$@";; *) exit 2;; esac
''')
        # Darwin uses a different stat format and F_GETPATH instead of procfs.
        if sys.platform == "darwin":
            self.script(tools / "stat", '''exec /usr/bin/stat -f '%Xp %z %m' "$3"''')
            (tools / "readlink").write_text(
                f"#!{sys.executable}\nimport fcntl, os\n"
                "os.write(1, fcntl.fcntl(3, fcntl.F_GETPATH, bytes(1024)).split(bytes(1))[0] + b'\\n')\n")
            (tools / "readlink").chmod(0o755)

    @staticmethod
    def script(path, body):
        path.write_text("#!/bin/sh\n" + body + "\n")
        path.chmod(0o755)

    async def command_bytes(self, *args, timeout=30):
        assert args[:3] == ("-s", "test-device", "shell")
        if args[3:5] == ("am", "get-current-user"):
            return b"10\n"
        assert args[3] == "-T"
        command = args[4].replace("/system/bin/sh", "/bin/sh", 1) if args[4].startswith("/system/bin/sh") else args[4]
        if sys.platform == "darwin":
            command = command.replace("/proc/self/fd/3", "/dev/fd/3")
        result = await asyncio.to_thread(subprocess.run, ["/bin/sh", "-c", command], cwd=self.root,
                                         env=self.env, capture_output=True, timeout=timeout)
        if result.returncode:
            raise ConnectionError(result.stderr.decode() or "permission denied")
        return result.stdout

    async def command(self, *args, **kwargs):
        return (await self.command_bytes(*args, **kwargs)).decode()


class AndroidSandboxTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.folder = Path(tmp.name)
        self.adb = LocalADB(self.folder)
        self.sandbox = sandbox.AndroidSandbox(self.adb, "test-device", "example.debug", "10")

    async def test_package_access_binary_ranges_and_finder_handle(self):
        apps = await sandbox.apps(self.adb, "test-device")
        self.assertEqual([(a["bundleIdentifier"], a["version"], a["containerAccessible"]) for a in apps],
                         [("example.debug", "7", True), ("example.release", "8", False)])
        directory = self.adb.root / "files"
        directory.mkdir()
        name = "it's $file; with a newline\n"
        payload = bytes(range(256)) * 12
        (directory / name).write_bytes(payload)
        (directory / ".hidden").mkdir()
        entries = await self.sandbox.files("./files/")
        self.assertEqual([(f["kind"], f["name"]) for f in entries], [("directory", ".hidden"), ("file", name)])
        self.assertEqual(entries[1]["size"], len(payload))
        path = entries[1]["path"]
        self.assertEqual(await self.sandbox.read(path, 127, 266), payload[127:393])
        self.assertTrue(stat.S_ISREG((await self.sandbox.os_stat("/" + path)).st_mode))
        handle = await self.sandbox.fopen("/" + path, "r")
        await self.sandbox.fseek(handle, 9, os.SEEK_SET)
        self.assertEqual(await self.sandbox.fread(handle, 100), payload[9:109])
        self.assertEqual(await self.sandbox.fread(handle, 5000), payload[109:])

    async def test_only_granted_package_and_regular_contained_files(self):
        (self.folder / "outside").write_bytes(b"outside")
        (self.adb.root / "link").symlink_to(self.folder / "outside")
        (self.adb.root / "parent").symlink_to(self.folder, target_is_directory=True)
        os.mkfifo(self.adb.root / "fifo")
        listing = await self.sandbox.files(".")
        self.assertEqual({f["kind"] for f in listing}, {"symbolicLink"})
        for path in ["link", "parent/outside", "../outside", "/outside", "fifo", "."]:
            with self.subTest(path=path), self.assertRaises(RpcError):
                await self.sandbox.read(path, 0, 100)
        with self.assertRaises(RpcError):
            await self.sandbox.files("parent")
        with self.assertRaises(RpcError):
            await sandbox.AndroidSandbox(self.adb, "test-device", "example.release", "10").files(".")
        with self.assertRaises(RpcError):
            await sandbox.AndroidSandbox(self.adb, "test-device", "example.debug", "0").files(".")
        for name in ["../test", "-h", "pkg;false"]:
            with self.assertRaises(RpcError):
                sandbox.AndroidSandbox(self.adb, "test-device", name, "10")

    @unittest.skipUnless(os.environ.get("PHONEUSE_TEST_ANDROID_FINDER") == "1", "Opt-in macOS WebDAV mount")
    async def test_native_finder_volume_with_replayed_device(self):
        data = bytes(range(251)) * 5000
        (self.adb.root / "payload.bin").write_bytes(data)
        mounts = sandbox.AndroidMounts(self.adb, "test-device", "10")
        mounts.root = self.folder / "mounts"
        try:
            volume = await mounts.mount("example.debug", "PhoneUse Android Test")
            path = Path(volume["path"])
            self.assertTrue((await asyncio.to_thread(os.statvfs, path)).f_flag & os.ST_RDONLY)
            self.assertEqual(await asyncio.to_thread((path / "payload.bin").read_bytes), data)
            await mounts.unmount(volume["id"])
            self.assertFalse(mounts.snapshot())
        finally:
            await mounts.close()

    async def test_rpc_without_screen_worker(self):
        supervisor = Supervisor()
        supervisor.android = self.adb
        supervisor._record = MagicMock(return_value=SimpleNamespace(
            udid="android:test-device", platform="android", adb_state="device", adb_serial="test-device"))
        supervisor._worker = AsyncMock()
        (self.adb.root / "text").write_text("hello")
        args = {"udid": "android:test-device", "bundleID": "example.debug", "path": "text", "offset": 0, "size": 10}
        reply = await supervisor.dispatch("androidSandboxRead", args, None)
        self.assertEqual(base64.b64decode(reply["data"]), b"hello")
        self.assertEqual(reply["user"], "10")
        with self.assertRaises(RpcError):
            await supervisor.dispatch("androidSandboxRead", {**args, "user": "9"}, None)
        self.assertEqual(await supervisor.dispatch("sandboxMounts", args, None), {"mounts": []})
        supervisor._worker.assert_not_awaited()
