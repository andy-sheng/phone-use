import subprocess
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from devicehub_runtime import controller as controller_module
from devicehub_runtime.controller import ANDROID_INPUT_DENIED, DeviceController, check_android_input
from devicehub_runtime.runner import native_size, open_device


class DescribingBridge:
    def __init__(self, device):
        self.device = device
        self.calls = []
        self.closed = False
        self.process = SimpleNamespace(poll=lambda: None)

    def request(self, method, **params):
        self.calls.append(method)
        if method == "describe":
            return self.device
        if method == "connect":
            return {"udid": self.device["udid"], "name": self.device["name"], "width": 1179, "height": 2556}
        return {}

    def close(self):
        self.closed = True


class FakeAndroidController:
    def __init__(self, succeeded=True):
        self.succeeded = succeeded
        self.resolution = (1080, 2400)

    def post_connection(self):
        return SimpleNamespace(wait=lambda: SimpleNamespace(succeeded=self.succeeded))


ANDROID = {"udid": "android:SERIAL", "name": "Pixel", "platform": "android", "serial": "SERIAL",
           "adb": "/daemon/adb"}


def args(command="run"):
    return SimpleNamespace(command=command, bridge=Path("/bridge"), device="android:SERIAL")


class AndroidDeviceTests(unittest.TestCase):
    def test_android_uses_maa_native_controller_on_the_daemon_adb(self):
        bridge = DescribingBridge(ANDROID)
        created, checked = [], []
        controller = FakeAndroidController()

        def factory(adb, serial):
            created.append((adb, serial))
            return controller

        opened, info, kept = open_device(args(), lambda *_a, **_k: None, lambda *_: bridge, factory,
                                         lambda adb, serial: checked.append((adb, serial)))
        self.assertIs(opened, controller)
        self.assertEqual(created, [("/daemon/adb", "SERIAL")])
        self.assertEqual(checked, [("/daemon/adb", "SERIAL")])
        self.assertEqual(info["udid"], "android:SERIAL")
        self.assertIsNone(kept)
        # The bridge only resolves the device; it never opens an Android session.
        self.assertEqual(bridge.calls, ["describe"])
        self.assertTrue(bridge.closed)
        self.assertEqual(native_size(opened, info), [1080, 2400])

    def test_probe_does_not_check_input_permission(self):
        checked = []
        open_device(args("probe"), lambda *_a, **_k: None, lambda *_: DescribingBridge(ANDROID),
                    lambda *_: FakeAndroidController(), lambda *a: checked.append(a))
        self.assertEqual(checked, [])

    def test_input_denied_stops_before_creating_a_controller(self):
        bridge = DescribingBridge(ANDROID)

        def deny(*_):
            raise RuntimeError(ANDROID_INPUT_DENIED)

        with self.assertRaisesRegex(RuntimeError, "USB 调试"):
            open_device(args(), lambda *_a, **_k: None, lambda *_: bridge,
                        lambda *_: self.fail("controller created"), deny)
        self.assertTrue(bridge.closed)

    def test_failed_android_connection_is_reported(self):
        with self.assertRaisesRegex(RuntimeError, "MaaTouch"):
            open_device(args(), lambda *_a, **_k: None, lambda *_: DescribingBridge(ANDROID),
                        lambda *_: FakeAndroidController(succeeded=False), lambda *_: None)

    def test_ios_keeps_using_the_bridge_controller(self):
        bridge = DescribingBridge({"udid": "ios-udid", "name": "iPhone", "platform": "ios"})
        opened, info, kept = open_device(args(), lambda *_a, **_k: None, lambda *_: bridge,
                                         lambda *_: self.fail("Android controller used for iOS"),
                                         lambda *_: self.fail("Android input check used for iOS"))
        self.assertIsInstance(opened, DeviceController)
        self.assertIs(kept, bridge)
        self.assertFalse(bridge.closed)
        self.assertEqual(bridge.calls, ["describe", "connect"])
        self.assertEqual(native_size(opened, info), [1179, 2556])


class InputPermissionTests(unittest.TestCase):
    def result(self, returncode=0, stdout="", stderr=""):
        return SimpleNamespace(returncode=returncode, stdout=stdout, stderr=stderr)

    def test_probe_sends_unknown_key_through_the_given_adb(self):
        with patch.object(controller_module.subprocess, "run", return_value=self.result()) as run:
            check_android_input("/daemon/adb", "SERIAL")
        self.assertEqual(run.call_args.args[0], ["/daemon/adb", "-s", "SERIAL", "shell", "input", "keyevent", "0"])

    def test_security_exception_is_reported_even_on_success_exit(self):
        with patch.object(controller_module.subprocess, "run",
                          return_value=self.result(stderr="java.lang.SecurityException: INJECT_EVENTS")):
            with self.assertRaisesRegex(RuntimeError, "USB 调试"):
                check_android_input("/adb", "SERIAL")

    def test_adb_failure_and_timeout_do_not_pass(self):
        with patch.object(controller_module.subprocess, "run", return_value=self.result(1, stderr="offline")):
            with self.assertRaisesRegex(RuntimeError, "offline"):
                check_android_input("/adb", "SERIAL")
        with patch.object(controller_module.subprocess, "run", side_effect=subprocess.TimeoutExpired("adb", 5)):
            with self.assertRaises(RuntimeError):
                check_android_input("/adb", "SERIAL")


class NativeControllerTests(unittest.TestCase):
    def test_factory_requests_real_touch_input_methods(self):
        from maa.define import MaaAdbInputMethodEnum

        with patch("maa.controller.AdbController") as adb_controller:
            controller_module.make_android_controller("/daemon/adb", "SERIAL")
        args, kwargs = adb_controller.call_args
        self.assertEqual(args, ("/daemon/adb", "SERIAL"))
        self.assertEqual(kwargs["input_methods"],
                         MaaAdbInputMethodEnum.Maatouch | MaaAdbInputMethodEnum.MinitouchAndAdbKey)


if __name__ == "__main__":
    unittest.main()
