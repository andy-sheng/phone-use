import base64
import math
import unittest
from pathlib import Path
from types import SimpleNamespace

import numpy as np
from maa.define import LoggingLevelEnum
from maa.tasker import Tasker

from devicehub_runtime.controller import DeviceController
from devicehub_runtime.images import encode_png


class FakeBridge:
    def __init__(self):
        self.calls = []
        self.process = SimpleNamespace(poll=lambda: None)
        self.png = base64.b64encode(encode_png(np.full((2556, 1179, 3), 30, np.uint8))).decode()

    def request(self, method, **params):
        self.calls.append((method, params))
        if method == "connect":
            return {"udid": "fixture", "width": 1179, "height": 2556}
        if method == "screenshot":
            return {"png": self.png}
        return {}


class MaaCoordinateTests(unittest.TestCase):
    def setUp(self):
        path = Path(__file__).resolve().parents[2] / ".build/automation/tests"
        path.mkdir(parents=True, exist_ok=True)
        Tasker.set_log_dir(path)

    def test_native_framework_maps_recognition_pixels_back_to_native_pixels(self):
        Tasker.set_stdout_level(LoggingLevelEnum.Off)
        bridge = FakeBridge()
        controller = DeviceController(bridge)
        self.assertTrue(controller.post_connection().wait().succeeded)
        self.assertTrue(controller.set_screenshot_target_short_side(720))
        image = controller.post_screencap().wait().get()
        self.assertEqual(image.shape[:2], (1561, 720))
        self.assertTrue(controller.post_click(360, 780).wait().succeeded)
        down = next(params for method, params in bridge.calls if method == "touch_down")
        self.assertEqual(down, {"x": math.floor(360 * 1179 / 720 + .5), "y": math.floor(780 * 2556 / 1561 + .5)})
        self.assertEqual(bridge.calls[-1][0], "touch_up")

    def test_unsupported_contact_does_not_send_input(self):
        bridge = FakeBridge()
        controller = DeviceController(bridge)
        self.assertFalse(controller.touch_down(1, 30, 40, 1))
        self.assertFalse(controller.input_text("unused"))
        self.assertEqual(bridge.calls, [])

    def test_android_uses_native_pixels_through_the_shared_bridge(self):
        class AndroidBridge(FakeBridge):
            def request(self, method, **params):
                if method == "connect":
                    return {"udid": "android:fixture", "name": "Android fixture", "platform": "android",
                            "width": 1080, "height": 2400}
                return super().request(method, **params)

        bridge = AndroidBridge()
        bridge.png = base64.b64encode(encode_png(np.zeros((2400, 1080, 3), np.uint8))).decode()
        controller = DeviceController(bridge)
        self.assertTrue(controller.post_connection().wait().succeeded)
        self.assertTrue(controller.set_screenshot_target_short_side(720))
        self.assertEqual(controller.post_screencap().wait().get().shape[:2], (1600, 720))
        self.assertTrue(controller.post_click(360, 800).wait().succeeded)
        down = next(params for method, params in bridge.calls if method == "touch_down")
        self.assertEqual(down, {"x": 540, "y": 1200})
        self.assertEqual(bridge.calls[-1][0], "touch_up")
        self.assertEqual(controller.info["platform"], "android")

    def test_changed_screen_dimensions_are_rejected_before_recognition(self):
        bridge = FakeBridge()
        controller = DeviceController(bridge)
        self.assertTrue(controller.post_connection().wait().succeeded)
        bridge.png = base64.b64encode(encode_png(np.zeros((1179, 2556, 3), np.uint8))).decode()
        self.assertIsNone(controller.screencap())
        self.assertEqual(controller.last_error, "Screen orientation or size changed")
        self.assertFalse(any(method.startswith("touch") for method, _ in bridge.calls))


if __name__ == "__main__":
    unittest.main()
