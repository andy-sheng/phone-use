import asyncio
import hashlib
import io
import json
import os
import struct
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock, patch

from devicehubd import android_video as video
from devicehubd import android_worker
from devicehubd.protocol import RpcError, encode
from devicehubd.supervisor import DeviceRecord, Supervisor

META = struct.pack(">4sII", b"h264", 808, 1920)
PAYLOAD = b"\0\0\0\1\x67\x42\x80\x20"
CONFIG = struct.pack(">QI", 1 << 63, len(PAYLOAD)) + PAYLOAD
FRAME = struct.pack(">QI", (1 << 62) | 1234567, len(PAYLOAD)) + PAYLOAD


class Writer:
    def __init__(self):
        self.data = bytearray()
        self.closed = False
        self.transport = SimpleNamespace(set_write_buffer_limits=MagicMock())
        self.drain = AsyncMock()

    def write(self, data):
        self.data.extend(data)

    def close(self):
        self.closed = True

    async def wait_closed(self):
        pass

    def get_extra_info(self, name):
        return None


class Process:
    def __init__(self):
        self.stdout = asyncio.StreamReader()
        self.returncode = None
        self.done = asyncio.Event()
        self.signals = []

    async def wait(self):
        await self.done.wait()
        return self.returncode

    def terminate(self):
        self.signals.append("terminate")
        self.returncode = -15
        self.done.set()

    def kill(self):
        self.signals.append("kill")
        self.returncode = -9
        self.done.set()


class ProtocolTests(unittest.TestCase):
    def test_metadata_and_frame_bounds(self):
        self.assertEqual(video.validate_metadata(META), (808, 1920))
        self.assertEqual(video.packet_size(CONFIG[:12]), len(PAYLOAD))
        for value in (b"", struct.pack(">4sII", b"h265", 808, 1920),
                      struct.pack(">4sII", b"h264", 0, 1920), struct.pack(">4sII", b"h264", 1928, 1920)):
            with self.subTest(value=value), self.assertRaises(RpcError):
                video.validate_metadata(value)
        for size in (0, video.MAX_PACKET_SIZE + 1, 0xffffffff):
            with self.subTest(size=size), self.assertRaises(RpcError):
                video.packet_size(struct.pack(">QI", 0, size))

    def test_asset_override_requires_pinned_digest(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "server"
            path.write_bytes(b"trusted server fixture")
            with patch.dict(os.environ, {"DEVICEHUB_SCRCPY_SERVER": str(path)}):
                with self.assertRaisesRegex(RpcError, "SHA-256"):
                    video.server_path()
                with patch.object(video, "SERVER_SHA256", hashlib.sha256(path.read_bytes()).hexdigest()):
                    self.assertEqual(video.server_path(), path)

    def test_bundled_assets_directory_supplies_server(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / video.SERVER_FILENAME
            path.write_bytes(b"bundled server fixture")
            with patch.dict(os.environ, {"DEVICEHUB_ANDROID_ASSETS": directory}), \
                    patch.object(video, "SERVER_SHA256", hashlib.sha256(path.read_bytes()).hexdigest()):
                os.environ.pop("DEVICEHUB_SCRCPY_SERVER", None)
                self.assertEqual(video.server_path(), path)

    def test_pinned_server_matches_asset_manifest(self):
        manifest = json.loads((Path(__file__).resolve().parents[2] / "scripts/android-assets.json").read_text())["scrcpy"]
        self.assertEqual((manifest["version"], manifest["filename"], manifest["sha256"]),
                         (video.SERVER_VERSION, video.SERVER_FILENAME, video.SERVER_SHA256))


class SessionTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.sessions = []

    async def asyncTearDown(self):
        for session in self.sessions:
            await session.close()

    def session(self):
        session = video.AndroidVideoSession("/a path/adb", "serial;not-a-shell")
        session._adb = AsyncMock(return_value=b"")
        self.sessions.append(session)
        return session

    async def start_session(self, *, metadata=META):
        session = self.session()
        session._adb.side_effect = lambda *args, **kwargs: b"12345\n" if args[0] == "forward" and args[1] == "tcp:0" else b""
        process = Process()
        upstream = asyncio.StreamReader()
        upstream.feed_data(b"\0" + metadata)
        upstream_writer = Writer()
        listener = SimpleNamespace(close=MagicMock(), wait_closed=AsyncMock(),
                                   sockets=[SimpleNamespace(getsockname=lambda: ("127.0.0.1", 23456))])

        async def spawn(*args, **kwargs):
            self.assertEqual(args[:4], ("/a path/adb", "-s", "serial;not-a-shell", "shell"))
            self.assertEqual(kwargs["stdin"], asyncio.subprocess.DEVNULL)
            self.assertIn("control=false", args[4])
            self.assertIn("power_on=false", args[4])
            self.assertIn("audio=false", args[4])
            self.assertIn("video_codec=h264", args[4])
            self.assertIn("max_size=1920 max_fps=60 video_bit_rate=8000000", args[4])
            self.assertRegex(args[4], r"scid=[0-7][0-9a-f]{7}")
            process.stdout.feed_data((session.marker + ":123\n").encode())
            return process

        with patch.object(video, "server_path", return_value=Path("/fixture/server")), \
                patch.object(video.asyncio, "create_subprocess_exec", side_effect=spawn), \
                patch.object(video.asyncio, "open_connection", new=AsyncMock(return_value=(upstream, upstream_writer))), \
                patch.object(video.asyncio, "start_server", new=AsyncMock(return_value=listener)) as listen:
            result = await session.start()
        self.assertEqual(result, {"port": 23456, "token": session.token})
        self.assertEqual(session.metadata, metadata)
        self.assertEqual(session.remote_pid, 123)
        self.assertEqual(listen.call_args.args[1:3], ("127.0.0.1", 0))
        return session, upstream, upstream_writer, process

    async def test_start_validates_metadata_before_publishing_port_and_cleans_own_resources(self):
        session, _, upstream_writer, process = await self.start_session()
        remote, scid = session.remote, session.scid
        await session.close()
        self.assertTrue(upstream_writer.closed)
        self.assertTrue(session.listener.close.called)
        self.assertIsNotNone(process.returncode)
        calls = [call.args for call in session._adb.await_args_list]
        self.assertIn(("push", "/fixture/server", remote), calls)
        self.assertIn(("forward", "tcp:0", f"localabstract:scrcpy_{scid}"), calls)
        self.assertIn(("forward", "--remove", "tcp:12345"), calls)
        cleanup = next(args[1] for args in calls if args[0] == "shell" and "kill -9" in args[1])
        self.assertIn(f"DEVICEHUB_VIDEO_OWNER={session.marker}", cleanup)
        self.assertIn("/proc/123/environ", cleanup)
        self.assertIn("kill -9 123", cleanup)
        self.assertIn(f"rm -f {remote}", cleanup)
        self.assertNotIn("pkill", cleanup)
        count = session._adb.await_count
        await session.close()
        self.assertEqual(session._adb.await_count, count)

    async def test_invalid_metadata_never_publishes_relay_and_reaps_server(self):
        with self.assertRaises(RpcError):
            await self.start_session(metadata=struct.pack(">4sII", b"h265", 100, 100))
        session = self.sessions[-1]
        self.assertTrue(session.closed)
        self.assertIsNone(session.listener)
        self.assertIsNotNone(session.process.returncode)

    async def test_missing_asset_does_not_run_adb(self):
        session = self.session()
        with patch.object(video, "server_path", side_effect=RpcError("androidVideoUnavailable", "missing")):
            with self.assertRaises(RpcError):
                await session.start()
        session._adb.assert_not_awaited()

    async def test_raw_packet_flags_pts_and_payload_are_preserved(self):
        session, upstream, _, _ = await self.start_session()
        upstream.feed_data(CONFIG + FRAME)
        upstream.feed_eof()
        reader = asyncio.StreamReader()
        reader.feed_data((session.token + "\n").encode())
        writer = Writer()
        session._auth_count = 1
        await session._serve(reader, writer)
        self.assertEqual(bytes(writer.data), META + CONFIG + FRAME)
        self.assertTrue(session.claimed)
        await session.close()

    async def test_bad_token_does_not_claim_or_destroy_stream(self):
        session, _, _, _ = await self.start_session()
        reader = asyncio.StreamReader()
        reader.feed_data(b"wrong-token\n")
        writer = Writer()
        session._auth_count = 1
        await session._serve(reader, writer)
        self.assertTrue(writer.closed)
        self.assertFalse(session.claimed)
        self.assertFalse(session.closed)
        self.assertEqual(writer.data, b"")

    async def test_consumer_disconnect_reclaims_session_without_waiting_for_next_frame(self):
        session, _, _, _ = await self.start_session()
        reader = asyncio.StreamReader()
        reader.feed_data((session.token + "\n").encode())
        reader.feed_eof()
        writer = Writer()
        session._auth_count = 1
        await asyncio.wait_for(session._serve(reader, writer), .2)
        self.assertTrue(session.closed)
        await session.close()

    async def test_static_display_can_idle_past_frame_timeout(self):
        session, upstream, _, _ = await self.start_session()
        upstream.feed_data(CONFIG + FRAME)
        reader = asyncio.StreamReader()
        reader.feed_data((session.token + "\n").encode())
        writer = Writer()
        session._auth_count = 1
        with patch.object(video, "FRAME_TIMEOUT", .01):
            serving = asyncio.create_task(session._serve(reader, writer))
            try:
                await asyncio.sleep(.05)
                self.assertEqual(bytes(writer.data), META + CONFIG + FRAME)
                self.assertFalse(serving.done())
                self.assertFalse(session.closed)
                # Idle must not prevent prompt cleanup when the consumer leaves.
                reader.feed_eof()
                await asyncio.wait_for(serving, .2)
                self.assertTrue(session.closed)
            finally:
                serving.cancel()
                await asyncio.gather(serving, return_exceptions=True)
        await session.close()

    async def test_announced_but_incomplete_payload_still_times_out(self):
        session = self.session()
        reader = asyncio.StreamReader()
        reader.feed_data(FRAME[:12])
        session.upstream_reader = reader
        writer = Writer()
        with patch.object(video, "FRAME_TIMEOUT", .01):
            with self.assertRaises(asyncio.TimeoutError):
                await session._forward(writer)
        self.assertEqual(writer.data, b"")

    async def test_unconsumed_stream_expires(self):
        with patch.object(video, "CONSUMER_TIMEOUT", .01):
            session, _, _, _ = await self.start_session()
            await asyncio.sleep(.03)
        self.assertTrue(session.closed)
        await session.close()

    async def test_second_consumer_is_rejected(self):
        session = self.session()
        session.claimed = True
        writer = Writer()
        session._accept(asyncio.StreamReader(), writer)
        self.assertTrue(writer.closed)
        self.assertEqual(len(session._tasks), 0)

    async def test_oversized_packet_is_rejected_before_payload_read(self):
        session = self.session()
        reader = SimpleNamespace(readexactly=AsyncMock(return_value=struct.pack(">QI", 0, video.MAX_PACKET_SIZE + 1)))
        session.upstream_reader = reader
        with self.assertRaises(RpcError):
            await session._forward(Writer())
        reader.readexactly.assert_awaited_once_with(12)

    async def test_slow_consumer_fails_instead_of_buffering_following_packets(self):
        session = self.session()
        reader = asyncio.StreamReader()
        reader.feed_data(CONFIG + FRAME)
        session.upstream_reader = reader
        writer = Writer()
        writer.drain.side_effect = lambda: asyncio.sleep(10)
        with patch.object(video, "WRITE_TIMEOUT", .01):
            # AsyncMock returns the coroutine from a synchronous side effect, so
            # install the actual blocking coroutine as the writer's method.
            async def blocked():
                await asyncio.sleep(10)
            writer.drain = blocked
            with self.assertRaises(asyncio.TimeoutError):
                await session._forward(writer)
        self.assertEqual(bytes(writer.data), CONFIG)

    async def test_canceled_start_cleans_upload_and_forward(self):
        session = self.session()
        started = asyncio.Event()

        async def starting():
            session._upload_attempted = True
            session.forward_port = 23456
            started.set()
            await asyncio.Future()

        session._start = starting
        task = asyncio.create_task(session.start())
        await started.wait()
        task.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await task
        self.assertTrue(session.closed)
        self.assertIn(("forward", "--remove", "tcp:23456"), [call.args for call in session._adb.await_args_list])

    async def test_adb_timeout_and_output_limit_kill_and_reap(self):
        for excessive in (False, True):
            process = Process()
            if excessive:
                process.stdout.feed_data(b"x" * (video.MAX_ADB_OUTPUT + 1))
            session = video.AndroidVideoSession("/adb", "serial")
            with patch.object(video.asyncio, "create_subprocess_exec", new=AsyncMock(return_value=process)):
                with self.assertRaises((asyncio.TimeoutError, RpcError)):
                    await session._adb("anything", timeout=.01)
            self.assertIn("kill", process.signals)
            self.assertIsNotNone(process.returncode)


class ManagerTests(unittest.IsolatedAsyncioTestCase):
    async def test_old_stop_token_cannot_stop_replacement(self):
        sessions = []

        def factory(adb, serial):
            session = SimpleNamespace(token=str(len(sessions)), close=AsyncMock(), start=AsyncMock(return_value={}))
            sessions.append(session)
            return session

        manager = video.AndroidVideoManager("/adb", "serial", session_factory=factory)
        await manager.start()
        await manager.start()
        sessions[0].close.assert_awaited_once()
        await manager.stop(sessions[0].token)
        sessions[1].close.assert_not_awaited()
        await manager.stop(sessions[1].token)
        sessions[1].close.assert_awaited_once()
        await manager.close()
        with self.assertRaises(RpcError):
            await manager.start()

    async def test_close_waits_for_inflight_start_and_prevents_reopen(self):
        entered, finish = asyncio.Event(), asyncio.Event()

        async def start():
            entered.set()
            await finish.wait()
            return {}

        session = SimpleNamespace(token="token", start=start, close=AsyncMock())
        manager = video.AndroidVideoManager("/adb", "serial", session_factory=lambda *_: session)
        starting = asyncio.create_task(manager.start())
        await entered.wait()
        closing = asyncio.create_task(manager.close())
        await asyncio.sleep(0)
        self.assertFalse(closing.done())
        finish.set()
        await asyncio.gather(starting, closing)
        session.close.assert_awaited_once()
        self.assertTrue(manager.closed)


class RoutingTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        with patch("devicehubd.supervisor._load_cache", return_value={}):
            self.supervisor = Supervisor()
        self.record = DeviceRecord("android:x", "usb", platform="android", adb_serial="x", adb_state="device")
        self.supervisor.records[self.record.udid] = self.record
        self.worker = SimpleNamespace(command_lock=asyncio.Lock(), stopping=False,
                                      process=SimpleNamespace(returncode=None), call=AsyncMock(return_value={"port": 123, "token": "abc"}))
        self.supervisor._worker = AsyncMock(return_value=self.worker)
        self.supervisor.workers[self.record.udid] = self.worker

    async def test_video_start_and_token_stop_route_to_android_worker(self):
        result = await self.supervisor.dispatch("startAndroidVideo", {"udid": "android:x"}, None)
        self.assertEqual(result, {"port": 123, "token": "abc"})
        self.worker.call.assert_awaited_with("startAndroidVideo", {}, timeout=35)
        await self.supervisor.dispatch("stopAndroidVideo", {"udid": "android:x", "token": "abc"}, None)
        self.worker.call.assert_awaited_with("stopAndroidVideo", {"token": "abc"}, timeout=35)
        self.supervisor._worker.assert_awaited_once()

    async def test_stop_after_worker_exit_does_not_open_replacement(self):
        self.supervisor.workers.clear()
        result = await self.supervisor.dispatch("stopAndroidVideo", {"udid": "android:x", "token": "old"}, None)
        self.assertEqual(result, {})
        self.supervisor._worker.assert_not_awaited()

    async def test_video_rejects_ios_and_bad_parameters(self):
        self.supervisor.records["ios"] = DeviceRecord("ios", "usb")
        for method, params in [("startAndroidVideo", {"udid": "ios"}),
                               ("stopAndroidVideo", {"udid": "ios", "token": "abc"}),
                               ("startAndroidVideo", {"udid": 1}),
                               ("stopAndroidVideo", {"udid": "android:x"})]:
            with self.subTest(method=method, params=params), self.assertRaises(RpcError):
                await self.supervisor.dispatch(method, params, None)
        self.worker.call.assert_not_awaited()


class WorkerShutdownTests(unittest.IsolatedAsyncioTestCase):
    async def test_rpc_eof_cancels_pending_video_start_and_cleans_manager(self):
        loop = asyncio.get_running_loop()
        reader = None
        connected, starting, canceled = asyncio.Event(), asyncio.Event(), asyncio.Event()

        async def connect_pipe(factory, pipe):
            nonlocal reader
            reader = factory()._stream_reader
            connected.set()
            return None, None

        async def start():
            starting.set()
            try:
                await asyncio.Future()
            finally:
                canceled.set()

        manager = SimpleNamespace(start=start, close=AsyncMock())
        device = SimpleNamespace(start=MagicMock(return_value={"display": {}}), close=MagicMock())
        with patch.object(loop, "connect_read_pipe", side_effect=connect_pipe), \
                patch.object(loop, "add_signal_handler"), \
                patch.object(android_worker, "AndroidDevice", return_value=device), \
                patch.object(android_worker, "AndroidVideoManager", return_value=manager):
            running = asyncio.create_task(android_worker.run("/adb", "serial", io.BytesIO()))
            await connected.wait()
            reader.feed_data(encode({"id": 1, "method": "startAndroidVideo", "params": {}}))
            await starting.wait()
            reader.feed_eof()
            self.assertEqual(await asyncio.wait_for(running, .5), 0)
        self.assertTrue(canceled.is_set())
        manager.close.assert_awaited()
        device.close.assert_called_once()


if __name__ == "__main__":
    unittest.main()
