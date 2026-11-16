import asyncio
import base64
import io
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock, patch

import numpy as np
from PIL import Image

from devicehubd.android import AndroidAttachment, AndroidDiscovery, find_adb, parse_devices
from devicehubd.android_display import DisplayGeometry
from devicehubd.android_worker import AndroidDevice, check_input_permission
from devicehubd.protocol import RpcError, encode
from devicehubd.supervisor import (
    ANDROID_DISCOVERY_FAILURE_LIMIT, DeviceRecord, Supervisor, WorkerHandle, WORKER_READ_LIMIT,
)


class DiscoveryTests(unittest.TestCase):
    def test_usb_network_emulator_and_authorization_states(self):
        devices = parse_devices("""List of devices attached
usb123 device usb:1-2 product:p model:Pixel_9 device:tokay transport_id:1
usb456 unauthorized usb:1-3 transport_id:2
10.0.0.1:5555 offline transport_id:3
emulator-5554 device product:sdk model:SDK_Phone transport_id:4
blocked no permissions (user in plugdev group; are your udev rules wrong?)
* daemon started successfully
""")
        self.assertEqual([d.udid for d in devices], ["android:usb123", "android:usb456", "android:10.0.0.1:5555", "android:emulator-5554", "android:blocked"])
        self.assertEqual([d.connection for d in devices[:4]], ["usb", "usb", "network", "emulator"])
        self.assertEqual(devices[0].name, "Pixel 9")
        self.assertEqual(devices[-1].state, "noPermissions")
        for state, expected in [("device", "ready"), ("unauthorized", "unauthorized"), ("offline", "offline")]:
            record = DeviceRecord("android:x", "usb", platform="android", adb_state=state)
            self.assertEqual(record.state, expected)
            self.assertEqual(record.to_json()["platform"], "android")
            self.assertFalse(record.image_needs_tunnel)
        record.attached = False
        self.assertEqual(record.state, "disconnected")

    def test_explicit_adb_override_does_not_fall_back(self):
        with patch.dict(os.environ, {"DEVICEHUB_ADB": "/missing/custom-adb"}), patch("devicehubd.android.shutil.which", return_value=None):
            self.assertIsNone(find_adb())

    def test_adb_override_and_sdk_location(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "adb"
            executable.write_text("#!/bin/sh\n")
            executable.chmod(0o755)
            with patch.dict(os.environ, {"DEVICEHUB_ADB": str(executable)}):
                self.assertEqual(find_adb(), str(executable))
            with patch.dict(os.environ, {}, clear=True), patch("devicehubd.android.shutil.which", return_value=None), patch("devicehubd.android.Path.home", return_value=Path(directory)):
                sdk = Path(directory) / "Library/Android/sdk/platform-tools/adb"
                sdk.parent.mkdir(parents=True)
                sdk.write_text("#!/bin/sh\n")
                sdk.chmod(0o755)
                self.assertEqual(find_adb(), str(sdk))

    def test_user_adb_is_preferred_over_bundled_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            bundled = Path(directory) / "assets/platform-tools/adb"
            user = Path(directory) / "Library/Android/sdk/platform-tools/adb"
            for path in (bundled, user):
                path.parent.mkdir(parents=True)
                path.write_text("#!/bin/sh\n")
                path.chmod(0o755)
            real_is_file = Path.is_file
            only_fixture = lambda path: str(path).startswith(directory) and real_is_file(path)
            with patch.dict(os.environ, {"DEVICEHUB_ANDROID_ASSETS": str(Path(directory) / "assets")}, clear=True), \
                    patch("devicehubd.android.shutil.which", return_value=None), \
                    patch("devicehubd.android.Path.home", return_value=Path(directory)), \
                    patch.object(Path, "is_file", only_fixture):
                self.assertEqual(find_adb(), str(user))
                user.unlink()
                self.assertEqual(find_adb(), str(bundled))

    def test_development_cache_supplies_adb_without_sdk_or_path_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            cached = root / ".build/android/platform-tools/adb"
            user = root / "sdk/platform-tools/adb"
            for path in (cached, user):
                path.parent.mkdir(parents=True)
                path.write_text("#!/bin/sh\n")
                path.chmod(0o755)
            real_is_file = Path.is_file
            only_fixture = lambda path: path.is_relative_to(root) and real_is_file(path)
            with patch.dict(os.environ, {}, clear=True), \
                    patch("devicehubd.android.__file__", str(root / "Daemon/devicehubd/android.py")), \
                    patch("devicehubd.android.shutil.which", return_value=None), \
                    patch("devicehubd.android.Path.home", return_value=root), \
                    patch.object(Path, "is_file", only_fixture):
                self.assertEqual(find_adb(), str(cached))
                with patch.dict(os.environ, {"ANDROID_HOME": str(root / "sdk")}):
                    self.assertEqual(find_adb(), str(user))
                with patch.dict(os.environ, {"DEVICEHUB_ANDROID_ASSETS": str(root / "missing-bundle")}):
                    self.assertIsNone(find_adb())


class DiscoveryAsyncTests(unittest.IsolatedAsyncioTestCase):
    async def test_adb_invoked_without_shell(self):
        process = SimpleNamespace(returncode=0, communicate=AsyncMock(return_value=(b"List of devices attached\nx device model:Pixel\n", b"")))
        with patch("devicehubd.android.find_adb", return_value="/a path/adb"), patch("devicehubd.android.asyncio.create_subprocess_exec", new=AsyncMock(return_value=process)) as spawn:
            found = await AndroidDiscovery().attached()
        self.assertEqual(found[0].serial, "x")
        self.assertEqual(spawn.call_args.args, ("/a path/adb", "devices", "-l"))

    async def test_timeout_kills_and_reaps_adb(self):
        async def forever():
            await asyncio.Future()
        process = SimpleNamespace(returncode=None, communicate=forever, kill=MagicMock(), wait=AsyncMock())
        discovery = AndroidDiscovery()
        discovery.adb_path = "/adb"
        with patch("devicehubd.android.asyncio.create_subprocess_exec", new=AsyncMock(return_value=process)):
            with self.assertRaises(asyncio.TimeoutError):
                await discovery.command("devices", timeout=0.01)
        process.kill.assert_called_once()
        process.wait.assert_awaited_once()


class Job:
    def __init__(self, succeeded=True, image=None):
        self.done, self.succeeded, self.image = True, succeeded, image

    def get(self):
        return self.image


class FakeController:
    def __init__(self):
        self.image = np.zeros((2400, 1080, 3), dtype=np.uint8)
        self.image[0, 0] = [13, 23, 33]
        self.calls = []
        self.fail = None
        self.raw = None
        self.native = None

    @property
    def resolution(self):
        return self.native or (self.image.shape[1], self.image.shape[0])

    def set_screenshot_use_raw_size(self, enabled):
        self.raw = enabled
        return True

    def post_connection(self):
        return Job()

    def post_screencap(self):
        self.calls.append(("capture",))
        return Job(self.fail != "capture", self.image)

    def _job(self, name, *args):
        self.calls.append((name, *args))
        return Job(self.fail != name)

    def post_touch_down(self, *args): return self._job("down", *args)
    def post_touch_move(self, *args): return self._job("move", *args)
    def post_touch_up(self): return self._job("up")
    def post_click(self, *args): return self._job("tap", *args)
    def post_swipe(self, *args): return self._job("swipe", *args)
    def post_click_key(self, *args): return self._job("key", *args)
    def post_key_down(self, *args): return self._job("key_down", *args)
    def post_key_up(self, *args): return self._job("key_up", *args)
    def post_start_app(self, *args): return self._job("launch", *args)


class DeviceTests(unittest.TestCase):
    def setUp(self):
        self.controller = FakeController()
        self.permission_checker = MagicMock()
        self.geometry_reader = MagicMock(return_value=DisplayGeometry(1080, 2400, 0))
        self.device = AndroidDevice("/adb", "serial", controller_factory=lambda *_: self.controller,
                                    permission_checker=self.permission_checker, geometry_reader=self.geometry_reader)
        self.info = self.device.start()
        self.controller.calls.clear()
        self.geometry_reader.reset_mock()

    def tearDown(self):
        self.device.close()

    def test_native_resolution_and_png_color(self):
        self.assertTrue(self.controller.raw)
        self.assertEqual(self.info["display"], {"pixelWidth": 1080, "pixelHeight": 2400, "pointScale": 1})
        result = self.device.command({"action": "screenshot"})
        image = Image.open(io.BytesIO(base64.b64decode(result["png"])))
        self.assertEqual(image.size, (1080, 2400))
        self.assertEqual(image.getpixel((0, 0)), (33, 23, 13))

    def test_normalized_coordinates_preserve_native_pixels_and_edges(self):
        self.device.command({"action": "tap", "x": "0.5", "y": "1"})
        self.assertEqual(self.controller.calls, [("tap", 540, 2399)])
        self.device.command({"action": "tap", "x": str(137 / 1080), "y": str(263 / 2400)})
        self.assertEqual(self.controller.calls[-1], ("tap", 137, 263))

    def test_continuous_gesture_and_release_on_close(self):
        self.device.command({"action": "touch", "phase": "began", "x": "0", "y": "0"})
        self.device.command({"action": "touch", "phase": "moved", "x": "1", "y": "0.5"})
        self.assertEqual(self.controller.calls, [("down", 0, 0), ("move", 1079, 1200)])
        self.device.close()
        self.assertEqual(self.controller.calls[-1], ("up",))

    def test_one_session_cannot_move_or_lift_another_sessions_touch(self):
        self.device.command({"action": "touch", "phase": "began", "x": "0.5", "y": "0.5", "owner": "automation"})
        self.device.command({"action": "touch", "phase": "ended", "owner": "preview"})
        self.device.command({"action": "release", "owner": "preview"})
        with self.assertRaisesRegex(RpcError, "another session"):
            self.device.command({"action": "touch", "phase": "moved", "x": "0.2", "y": "0.2", "owner": "preview"})
        with self.assertRaisesRegex(RpcError, "already held"):
            self.device.command({"action": "tap", "x": "0.2", "y": "0.2", "owner": "preview"})
        self.assertNotIn(("up",), self.controller.calls)
        self.device.command({"action": "touch", "phase": "moved", "x": "0.6", "y": "0.6", "owner": "automation"})
        self.device.command({"action": "touch", "phase": "ended", "owner": "automation"})
        self.assertEqual(self.controller.calls[-2:], [("move", 648, 1440), ("up",)])
        self.assertFalse(self.device.held)

    def test_closing_the_worker_lifts_any_sessions_touch(self):
        self.device.command({"action": "touch", "phase": "began", "x": "0.5", "y": "0.5", "owner": "automation"})
        self.device.close()
        self.assertEqual(self.controller.calls[-1], ("up",))

    def test_same_point_swipe_is_long_press(self):
        self.device.command({"action": "swipe", "fromX": "0.5", "fromY": "0.5", "toX": "0.5", "toY": "0.5", "durationMs": "800"})
        self.assertEqual(self.controller.calls[-1], ("swipe", 540, 1200, 540, 1200, 800))

    def test_rotation_is_checked_before_input_and_remains_rejected(self):
        self.geometry_reader.return_value = DisplayGeometry(2400, 1080, 1)
        with self.assertRaisesRegex(RpcError, "orientation changed"):
            self.device.command({"action": "tap", "x": "0.5", "y": "0.5"})
        self.assertFalse(any(call[0] == "tap" for call in self.controller.calls))
        self.controller.image = np.zeros((2400, 1080, 3), dtype=np.uint8)
        with self.assertRaisesRegex(RpcError, "orientation changed"):
            self.device.command({"action": "screenshot"})

    def test_rotation_during_drag_releases_without_moving(self):
        self.device.command({"action": "touch", "phase": "began", "x": "0", "y": "0"})
        self.geometry_reader.return_value = DisplayGeometry(2400, 1080, 1)
        with self.assertRaises(RpcError):
            self.device.command({"action": "touch", "phase": "moved", "x": "0.2", "y": "0.2"})
        self.assertEqual(self.controller.calls[-1], ("up",))
        self.assertFalse(any(call[0] == "move" for call in self.controller.calls))

    def test_scaled_screenshot_is_rejected(self):
        self.controller.image = np.zeros((1280, 576, 3), dtype=np.uint8)
        self.controller.native = (1080, 2400)
        with self.assertRaisesRegex(RpcError, "native display"):
            self.device.command({"action": "screenshot"})

    def test_failed_gesture_is_not_replayed_and_releases(self):
        self.controller.fail = "down"
        with self.assertRaises(RpcError):
            self.device.command({"action": "touch", "phase": "began", "x": "0.2", "y": "0.3"})
        self.assertEqual([c[0] for c in self.controller.calls], ["down", "up"])
        self.assertFalse(self.device.held)

    def test_invalid_coordinates_and_types_do_not_send_input(self):
        for value in ("nan", "inf", "-0.1", "1.01", "bad", 0.5):
            with self.subTest(value=value), self.assertRaises(RpcError):
                self.device.command({"action": "tap", "x": value, "y": "0.5"})
        self.assertEqual(self.controller.calls, [])

    def test_buttons_launch_and_command_injection_rejected(self):
        for button, key in [("home", 3), ("back", 4), ("app_switch", 187), ("lock", 26)]:
            self.device.command({"action": "press", "button": button})
            self.assertEqual(self.controller.calls[-1], ("key", key))
        self.device.command({"action": "launch", "bundleID": "com.example.app/.MainActivity"})
        self.assertEqual(self.controller.calls[-1], ("launch", "com.example.app/.MainActivity"))
        with self.assertRaises(RpcError):
            self.device.command({"action": "press", "button": "siri"})
        with self.assertRaises(RpcError):
            self.device.command({"action": "launch", "bundleID": "com.app; reboot"})
        with self.assertRaises(RpcError):
            self.device.command({"action": "launch", "bundleID": "com.app/$HOME"})

    def test_release_is_allowed_after_timeout(self):
        self.device.held = True
        with self.assertRaises(RpcError):
            self.device._wait(SimpleNamespace(done=False), "test", timeout=0)
        with self.assertRaisesRegex(RpcError, "timed out"):
            self.device.command({"action": "tap", "x": "0", "y": "0"})
        self.device.command({"action": "release"})
        self.assertEqual(self.controller.calls, [("up",)])

    def test_readonly_connection_screenshot_and_launch_do_not_check_input(self):
        self.device.command({"action": "screenshot"})
        self.device.command({"action": "launch", "bundleID": "com.android.settings"})
        self.device.command({"action": "release"})
        self.permission_checker.assert_not_called()
        self.geometry_reader.assert_not_called()

    def test_input_never_waits_for_a_screenshot(self):
        # This phone's screencap takes 1.2 seconds. A failing/slow screencap
        # must not be on the path of clicks or individual drag samples.
        self.controller.post_screencap = MagicMock(side_effect=AssertionError("input requested a screenshot"))
        self.device.command({"action": "tap", "x": "0.5", "y": "0.5"})
        self.device.command({"action": "swipe", "fromX": "0.5", "fromY": "0.8", "toX": "0.5", "toY": "0.2"})
        self.device.command({"action": "touch", "phase": "began", "x": "0.5", "y": "0.8"})
        for index in range(10):
            self.device.command({"action": "touch", "phase": "moved", "x": "0.5", "y": str(0.7 - index * 0.05)})
        self.device.command({"action": "touch", "phase": "ended"})
        self.assertEqual([call[0] for call in self.controller.calls], ["tap", "swipe", "down"] + ["move"] * 10 + ["up"])

    def test_half_turn_during_drag_is_rejected_even_when_dimensions_match(self):
        self.device.command({"action": "touch", "phase": "began", "x": "0.5", "y": "0.5"})
        self.geometry_reader.return_value = DisplayGeometry(1080, 2400, 2)
        with self.assertRaisesRegex(RpcError, "orientation changed"):
            self.device.command({"action": "touch", "phase": "moved", "x": "0.5", "y": "0.2"})
        self.assertEqual(self.controller.calls, [("down", 540, 1200), ("up",)])

    def test_half_turn_after_open_is_rejected_before_the_first_touch(self):
        self.geometry_reader.return_value = DisplayGeometry(1080, 2400, 2)
        with self.assertRaisesRegex(RpcError, "orientation changed"):
            self.device.command({"action": "tap", "x": "0.5", "y": "0.5"})
        self.assertEqual(self.controller.calls, [])

    def test_failed_geometry_probe_releases_the_drag_without_sending_movement(self):
        self.device.command({"action": "touch", "phase": "began", "x": "0.5", "y": "0.5"})
        self.geometry_reader.side_effect = RpcError("displayCheckFailed", "offline")
        with self.assertRaisesRegex(RpcError, "offline"):
            self.device.command({"action": "touch", "phase": "moved", "x": "0.5", "y": "0.2"})
        self.assertEqual(self.controller.calls, [("down", 540, 1200), ("up",)])

    def test_first_input_checks_permission_once_per_worker(self):
        self.device.command({"action": "tap", "x": "0.5", "y": "0.5"})
        self.device.command({"action": "press", "button": "home"})
        self.device.command({"action": "swipe", "fromX": "0", "fromY": "0", "toX": "1", "toY": "1"})
        self.device.command({"action": "touch", "phase": "began", "x": "0.5", "y": "0.5"})
        self.device.command({"action": "touch", "phase": "ended"})
        self.permission_checker.assert_called_once_with("/adb", "serial")

    def test_permission_denied_prevents_every_initial_input_kind_and_allows_retry(self):
        actions = [
            {"action": "tap", "x": "0", "y": "0"},
            {"action": "swipe", "fromX": "0", "fromY": "0", "toX": "1", "toY": "1"},
            {"action": "touch", "phase": "began", "x": "0", "y": "0"},
            {"action": "press", "button": "home"},
        ]
        self.permission_checker.side_effect = RpcError("inputNotAllowed", "USB 调试（安全设置）")
        for action in actions:
            with self.subTest(action=action), self.assertRaises(RpcError) as caught:
                self.device.command(action)
            self.assertEqual(caught.exception.code, "inputNotAllowed")
        self.assertEqual(self.permission_checker.call_count, 4)
        self.assertEqual(self.controller.calls, [])
        self.permission_checker.side_effect = None
        self.device.command({"action": "tap", "x": "0", "y": "0"})
        self.assertEqual(self.permission_checker.call_count, 5)
        self.assertEqual(self.controller.calls[-1], ("tap", 0, 0))

    def test_close_during_permission_probe_prevents_late_input(self):
        self.permission_checker.side_effect = lambda *_: self.device.stopped.set()
        with self.assertRaisesRegex(RpcError, "closing"):
            self.device.command({"action": "tap", "x": "0", "y": "0"})
        self.assertEqual(self.controller.calls, [])


class InputPermissionTests(unittest.TestCase):
    def test_probe_uses_unknown_key_and_bounded_argv_subprocess(self):
        with patch("devicehubd.android_worker.subprocess.run", return_value=SimpleNamespace(returncode=0, stdout="", stderr="")) as run:
            check_input_permission("/a path/adb", "serial:5555")
        self.assertEqual(run.call_args.args[0], ["/a path/adb", "-s", "serial:5555", "shell", "input", "keyevent", "0"])
        self.assertEqual(run.call_args.kwargs["timeout"], 5)
        self.assertNotIn("shell", run.call_args.kwargs)

    def test_security_failure_is_detected_even_with_zero_exit_code(self):
        for detail in ("java.lang.SecurityException: denied", "Injecting input events requires INJECT_EVENTS permission"):
            with self.subTest(detail=detail), patch("devicehubd.android_worker.subprocess.run", return_value=SimpleNamespace(returncode=0, stdout="", stderr=detail)):
                with self.assertRaises(RpcError) as caught:
                    check_input_permission("/adb", "serial")
                self.assertEqual(caught.exception.code, "inputNotAllowed")
                self.assertIn("USB 调试（安全设置）", caught.exception.message)

    def test_other_adb_failures_and_timeout_do_not_pass_permission_check(self):
        with patch("devicehubd.android_worker.subprocess.run", return_value=SimpleNamespace(returncode=1, stdout="", stderr="device offline")):
            with self.assertRaises(RpcError) as caught:
                check_input_permission("/adb", "serial")
            self.assertEqual(caught.exception.code, "inputCheckFailed")
        with patch("devicehubd.android_worker.subprocess.run", side_effect=subprocess.TimeoutExpired("adb", 5)):
            with self.assertRaises(RpcError) as caught:
                check_input_permission("/adb", "serial")
            self.assertEqual(caught.exception.code, "inputCheckFailed")


class SupervisorTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        with patch("devicehubd.supervisor._load_cache", return_value={}):
            self.supervisor = Supervisor()
        self.supervisor.broadcast = AsyncMock()
        self.supervisor._schedule_probe = MagicMock()
        self.supervisor.android.adb_path = "/adb"
        self.supervisor.simulators.attached = AsyncMock(return_value=[])

    async def test_mixed_discovery_authorization_change_and_disconnect(self):
        ios = SimpleNamespace(connection="usb", attached=AsyncMock(return_value=[SimpleNamespace(udid="same", connection="usb")]))
        android = AndroidAttachment("same", "unauthorized", "usb", "Pixel", "Pixel")
        self.supervisor.android.attached = AsyncMock(return_value=[android])
        with patch("devicehubd.supervisor.DISCOVERIES", [ios]):
            await self.supervisor.poll_devices()
            self.assertEqual(set(self.supervisor.records), {"same", "android:same"})
            self.assertEqual(self.supervisor.records["same"].platform, "ios")
            self.assertEqual(self.supervisor.records["android:same"].state, "unauthorized")
            self.assertIn("authorization", self.supervisor.records["android:same"].error)
            self.supervisor.android.attached.return_value = [AndroidAttachment("same", "device", "usb", "Pixel")]
            await self.supervisor.poll_devices()
            self.assertEqual(self.supervisor.records["android:same"].state, "ready")
            worker = MagicMock()
            self.supervisor.workers["android:same"] = worker
            self.supervisor.android.attached.return_value = []
            await self.supervisor.poll_devices()
            self.assertEqual(self.supervisor.records["android:same"].state, "disconnected")
            worker.stop.assert_called_once()

    async def test_transient_adb_failure_keeps_android_sessions(self):
        self.supervisor.android.attached = AsyncMock(return_value=[AndroidAttachment("serial", "device", "usb", "Pixel")])
        with patch("devicehubd.supervisor.DISCOVERIES", []):
            await self.supervisor.poll_devices()
            worker = MagicMock()
            self.supervisor.workers["android:serial"] = worker
            self.supervisor.android.attached.side_effect = ConnectionError("adb server restarting")
            for _ in range(ANDROID_DISCOVERY_FAILURE_LIMIT - 1):
                await self.supervisor.poll_devices()
            self.assertEqual(self.supervisor.records["android:serial"].state, "ready")
            worker.stop.assert_not_called()
            await self.supervisor.poll_devices()
            self.assertEqual(self.supervisor.records["android:serial"].state, "disconnected")
            worker.stop.assert_called_once()

    def android_record(self):
        record = DeviceRecord("android:x", "usb", platform="android", adb_serial="x", adb_state="device")
        self.supervisor.records[record.udid] = record
        return record

    async def test_open_android_includes_display_and_does_not_probe_ios(self):
        record = self.android_record()
        ready = asyncio.get_running_loop().create_future()
        ready.set_result({"display": {"pixelWidth": 1080, "pixelHeight": 2400, "pointScale": 1}})
        worker = SimpleNamespace(process=SimpleNamespace(returncode=None), ready=ready, stopping=False)
        self.supervisor.workers[record.udid] = worker
        result = await self.supervisor.open_device(record.udid)
        self.assertEqual(result["platform"], "android")
        self.assertEqual(result["display"]["pixelHeight"], 2400)
        self.assertEqual(result["services"], [])

    async def test_android_actions_route_once_and_ios_service_rejects_android(self):
        record = self.android_record()
        worker = SimpleNamespace(command_lock=asyncio.Lock(), call=AsyncMock(return_value={"width": 1080}))
        self.supervisor._worker = AsyncMock(return_value=worker)
        params = {"udid": record.udid, "action": "screenshot"}
        result = await self.supervisor.dispatch("androidCommand", params, None)
        self.assertEqual(result["width"], 1080)
        worker.call.assert_awaited_once_with("androidCommand", params, timeout=65)
        for method in ("pair", "revealDeveloperMode", "mountDeveloperImage", "openService", "startMirror"):
            with self.subTest(method=method), self.assertRaises(RpcError):
                await self.supervisor.dispatch(method, {"udid": record.udid}, None)

    async def test_timeout_stops_worker_without_retry(self):
        record = self.android_record()
        worker = SimpleNamespace(command_lock=asyncio.Lock(), call=AsyncMock(side_effect=asyncio.TimeoutError), stop=MagicMock())
        self.supervisor._worker = AsyncMock(return_value=worker)
        with self.assertRaisesRegex(RpcError, "without replaying"):
            await self.supervisor.android_command({"udid": record.udid, "action": "tap", "x": "0", "y": "0"})
        worker.call.assert_awaited_once()
        worker.stop.assert_called_once()

    async def test_concurrent_android_requests_are_serialized(self):
        record = self.android_record()
        calls, active = [], 0

        async def call(method, params, timeout):
            nonlocal active
            active += 1
            self.assertEqual(active, 1)
            calls.append(params["action"])
            await asyncio.sleep(0.01)
            active -= 1
            return {}

        worker = SimpleNamespace(command_lock=asyncio.Lock(), call=call)
        self.supervisor._worker = AsyncMock(return_value=worker)
        await asyncio.gather(*(self.supervisor.android_command({"udid": record.udid, "action": action})
                               for action in ("tap", "screenshot", "release")))
        self.assertEqual(calls, ["tap", "screenshot", "release"])

    async def test_spawn_chooses_platform_module_and_large_reader(self):
        record = self.android_record()
        process = SimpleNamespace(returncode=None)
        with patch("devicehubd.supervisor.asyncio.create_subprocess_exec", new=AsyncMock(return_value=process)) as spawn, patch.object(self.supervisor, "_read_worker", new=AsyncMock()):
            worker = await self.supervisor._spawn_worker(record)
            await asyncio.sleep(0)
        self.assertEqual(spawn.call_args.args[2:], ("devicehubd.android_worker", "--adb", "/adb", "--serial", "x"))
        self.assertEqual(spawn.call_args.kwargs["limit"], WORKER_READ_LIMIT)
        self.assertIs(self.supervisor.workers[record.udid], worker)

    async def test_android_command_rejects_ios_and_nonstring_params(self):
        self.supervisor.records["ios"] = DeviceRecord("ios", "usb", paired=True, developer_mode=True, developer_image=True)
        with self.assertRaises(RpcError):
            await self.supervisor.android_command({"udid": "ios", "action": "tap"})
        with self.assertRaises(RpcError):
            await self.supervisor.android_command({"udid": "android:x", "x": 1})

    async def test_worker_reader_accepts_screenshot_larger_than_64k(self):
        record = self.android_record()
        stream = asyncio.StreamReader(limit=WORKER_READ_LIMIT)
        png = "a" * (512 * 1024)
        stream.feed_data(encode({"id": 1, "result": {"png": png}}))
        stream.feed_eof()
        process = SimpleNamespace(stdout=stream, wait=AsyncMock(return_value=0))
        ready = asyncio.get_running_loop().create_future()
        ready.set_result({})
        worker = WorkerHandle(process, ready)
        reply = asyncio.get_running_loop().create_future()
        worker.pending[1] = reply
        await self.supervisor._read_worker(record, worker)
        self.assertEqual((await reply)["png"], png)


class ControlledProcess:
    def __init__(self, *, exit_on_terminate=False, exit_on_kill=True):
        self.returncode = None
        self.closed_stdin = asyncio.Event()
        self.exited = asyncio.Event()
        self.stdin = SimpleNamespace(close=self.closed_stdin.set)
        self.exit_on_terminate, self.exit_on_kill = exit_on_terminate, exit_on_kill
        self.signals = []

    async def wait(self):
        await self.exited.wait()
        return self.returncode

    def finish(self, code=0):
        self.returncode = code
        self.exited.set()

    def terminate(self):
        self.signals.append("terminate")
        if self.exit_on_terminate:
            self.finish(-15)

    def kill(self):
        self.signals.append("kill")
        if self.exit_on_kill:
            self.finish(-9)


class WorkerLifecycleTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        with patch("devicehubd.supervisor._load_cache", return_value={}):
            self.supervisor = Supervisor()
        self.supervisor.broadcast = AsyncMock()
        self.record = DeviceRecord("android:x", "usb", platform="android", adb_serial="x", adb_state="device", session="open")
        self.supervisor.records[self.record.udid] = self.record
        self.process = ControlledProcess()
        self.old = self.handle(self.process)
        self.supervisor.workers[self.record.udid] = self.old

    def handle(self, process):
        ready = asyncio.get_running_loop().create_future()
        ready.set_result({"display": {"pixelWidth": 1080, "pixelHeight": 2400, "pointScale": 1}})
        return WorkerHandle(process, ready)

    async def asyncTearDown(self):
        self.process.finish()
        if self.old.stop_task:
            await asyncio.gather(self.old.stop_task, return_exceptions=True)

    async def replacement(self, record):
        self.assertIsNotNone(self.process.returncode, "old controller must exit before replacement starts")
        worker = self.handle(ControlledProcess())
        self.supervisor.workers[record.udid] = worker
        return worker

    async def test_close_waits_for_exit_and_blocks_concurrent_open(self):
        self.supervisor._spawn_worker = AsyncMock(side_effect=self.replacement)
        closing = asyncio.create_task(self.supervisor.close_device(self.record.udid))
        await self.process.closed_stdin.wait()
        opening = asyncio.create_task(self.supervisor.open_device(self.record.udid))
        await asyncio.sleep(0)
        self.assertFalse(closing.done())
        self.supervisor._spawn_worker.assert_not_awaited()
        self.assertIs(self.supervisor.workers[self.record.udid], self.old)
        self.process.finish()
        await closing
        self.assertEqual((await opening)["platform"], "android")
        self.supervisor._spawn_worker.assert_awaited_once()

    async def test_discovery_stop_also_blocks_open_until_old_worker_exits(self):
        self.supervisor._spawn_worker = AsyncMock(side_effect=self.replacement)
        self.old.stop()
        opening = asyncio.create_task(self.supervisor.open_device(self.record.udid))
        await asyncio.sleep(0)
        self.supervisor._spawn_worker.assert_not_awaited()
        self.process.finish()
        await opening
        self.supervisor._spawn_worker.assert_awaited_once()

    async def test_cancelled_close_keeps_shutdown_barrier(self):
        self.supervisor._spawn_worker = AsyncMock(side_effect=self.replacement)
        closing = asyncio.create_task(self.supervisor.close_device(self.record.udid))
        await self.process.closed_stdin.wait()
        closing.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await closing
        self.assertFalse(self.old.stop_task.cancelled())
        opening = asyncio.create_task(self.supervisor.open_device(self.record.udid))
        await asyncio.sleep(0)
        self.supervisor._spawn_worker.assert_not_awaited()
        self.process.finish()
        await opening

    async def test_open_cannot_return_late_ready_from_a_closed_session(self):
        self.old.ready = asyncio.get_running_loop().create_future()
        opening = asyncio.create_task(self.supervisor.open_device(self.record.udid))
        await asyncio.sleep(0)
        closing = asyncio.create_task(self.supervisor.close_device(self.record.udid))
        await self.process.closed_stdin.wait()
        self.process.finish()
        await closing
        self.old.ready.set_result({"display": {"pixelWidth": 1080, "pixelHeight": 2400, "pointScale": 1}})
        with self.assertRaisesRegex(RpcError, "closed while it was opening"):
            await opening

    async def test_unresponsive_worker_is_terminated_then_killed_and_reaped(self):
        with patch("devicehubd.supervisor.WORKER_STOP_GRACE", 0.01), patch("devicehubd.supervisor.WORKER_TERMINATE_GRACE", 0.01):
            await self.supervisor.close_device(self.record.udid)
        self.assertEqual(self.process.signals, ["terminate", "kill"])
        self.assertEqual(self.process.returncode, -9)
        self.assertNotIn(self.record.udid, self.supervisor.workers)

    async def test_failed_kill_keeps_worker_registered_and_prevents_replacement(self):
        self.process.exit_on_kill = False
        self.supervisor._spawn_worker = AsyncMock()
        with patch("devicehubd.supervisor.WORKER_STOP_GRACE", 0.01), patch("devicehubd.supervisor.WORKER_TERMINATE_GRACE", 0.01), patch("devicehubd.supervisor.WORKER_KILL_GRACE", 0.01), self.assertLogs("devicehubd", level="WARNING"):
            with self.assertRaisesRegex(RpcError, "not exited"):
                await self.supervisor.close_device(self.record.udid)
        self.assertIs(self.supervisor.workers[self.record.udid], self.old)
        with self.assertRaisesRegex(RpcError, "not exited"):
            await self.supervisor.open_device(self.record.udid)
        self.supervisor._spawn_worker.assert_not_awaited()

    async def test_closing_worker_rejects_new_commands(self):
        self.old.stop()
        with self.assertRaisesRegex(RpcError, "exited"):
            await self.old.call("androidCommand", {"action": "tap"})
        self.process.finish()
        await self.old.wait_closed()


if __name__ == "__main__":
    unittest.main()
