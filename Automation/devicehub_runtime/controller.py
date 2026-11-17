import base64
import json
import queue
import subprocess
import threading
import time
from pathlib import Path

import numpy as np
from maa.controller import CustomController
from maa.define import MaaControllerFeatureEnum

from .images import decode_png
from .diagnostics import BridgeTrace


class Bridge:
    """One persistent automation-bridge process per run; failed requests are never replayed.

    The bridge inherits the app's PhoneUseKit identity (``DEVICEHUB_HOME`` and friends) from this
    process's environment, so it reaches the same daemon the app started.
    """

    def __init__(self, executable: Path, device: str | None = None):
        args = [str(executable)]
        if device:
            args += ["--device", device]
        self.process = subprocess.Popen(
            args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            text=True, encoding="utf-8", bufsize=1,
        )
        self.trace = BridgeTrace()
        self.trace.record("bridge.start", child_pid=self.process.pid)
        self._responses = queue.Queue()
        self._lock = threading.Lock()
        self._serial = 0
        self._closed = False
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        try:
            for line in self.process.stdout:
                self._responses.put(json.loads(line))
        except Exception as error:
            self._responses.put(error)
        finally:
            self._responses.put(EOFError("automation-bridge disconnected"))

    def request(self, method: str, **params):
        with self._lock:
            if self._closed or self.process.poll() is not None:
                raise ConnectionError("automation-bridge is closed")
            self._serial += 1
            started = time.monotonic()
            context = {"request": self._serial, "method": method, "child_pid": self.process.pid,
                       "timeout_ms": 30000}
            self.trace.record("request.begin", **context)
            try:
                self.process.stdin.write(json.dumps({"id": self._serial, "method": method, "params": params}) + "\n")
                self.process.stdin.flush()
                try:
                    reply = self._responses.get(timeout=30)
                except queue.Empty as error:
                    self._closed = True
                    self.process.stdin.close()
                    raise TimeoutError(f"automation-bridge {method} timed out; run stopped") from error
                if isinstance(reply, Exception):
                    raise reply
                if reply.get("id") != self._serial:
                    raise ConnectionError("automation-bridge response ID mismatch")
                if "error" in reply:
                    raise RuntimeError(reply["error"])
                result = reply["result"]
            except Exception as error:
                self.trace.record("request.failed", **context, elapsed_ms=round((time.monotonic() - started) * 1000),
                                  error_type=type(error).__name__, child_exit=self.process.poll())
                raise
            self.trace.record("request.ok", **context, elapsed_ms=round((time.monotonic() - started) * 1000))
            return result

    def close(self):
        if not self._closed:
            try:
                self.request("release")
            except Exception:
                pass
            self.process.stdin.close()
            self._closed = True
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.trace.record("bridge.exit", child_exit=self.process.poll())
        self.trace.close()


class DeviceController(CustomController):
    """Maa supplies native-image pixels to these callbacks, after its own scaling.

    The Swift bridge converts those pixels to DeviceSession's normalized coordinates.
    Full-resolution BGR images preserve aspect ratio; there is no 720x1280 stretching.
    """

    def __init__(self, bridge: Bridge, emit=lambda *args, **kwargs: None):
        self.bridge = bridge
        self.emit = emit
        self.info = {}
        self.last_error = None
        self.last_image = None
        super().__init__()

    def _call(self, method, **params):
        try:
            return self.bridge.request(method, **params)
        except Exception as error:
            self.last_error = str(error)
            self.emit("error", message=f"设备连接失败：{error}")
            return None

    def connect(self):
        self.info = self._call("connect") or {}
        return bool(self.info)

    def connected(self):
        return bool(self.info) and self.bridge.process.poll() is None

    def request_uuid(self):
        return self.info.get("udid", "")

    def get_features(self):
        return int(MaaControllerFeatureEnum.UseMouseDownAndUpInsteadOfClick)

    def screencap(self):
        result = self._call("screenshot")
        if result is None:
            return None
        try:
            image = decode_png(base64.b64decode(result["png"], validate=True))
        except Exception as error:
            self.last_error = f"Invalid screenshot data: {error}"
            return None
        h, w = image.shape[:2]
        if (w, h) != (self.info["width"], self.info["height"]):
            self.last_error = "Screen orientation or size changed"
            return None
        self.last_image = image
        return np.ascontiguousarray(image)

    def click(self, x, y):
        return self._call("click", x=x, y=y) is not None

    def swipe(self, x1, y1, x2, y2, duration):
        return self._call("swipe", x1=x1, y1=y1, x2=x2, y2=y2, duration_ms=duration) is not None

    def touch_down(self, contact, x, y, pressure):
        return contact == 0 and self._call("touch_down", x=x, y=y) is not None

    def touch_move(self, contact, x, y, pressure):
        return contact == 0 and self._call("touch_move", x=x, y=y) is not None

    def touch_up(self, contact):
        return contact == 0 and self._call("touch_up") is not None

    def start_app(self, intent):
        return self._call("launch", bundle_id=intent) is not None

    def stop_app(self, intent):
        return False

    def click_key(self, keycode):
        return False

    def input_text(self, text):
        return False

    def key_down(self, keycode):
        return False

    def key_up(self, keycode):
        return False

    def scroll(self, dx, dy):
        return False


ANDROID_INPUT_DENIED = (
    "Android 拒绝注入触摸或按键。请在开发者选项中开启“USB 调试（安全设置）”"
    "（小米/红米等设备需单独开启），完成手机上的确认后重试；如系统要求，请重启手机。"
)


def make_android_controller(adb_path: str, serial: str):
    """MaaFramework's own Android controller, on the adb executable the device daemon uses."""
    from maa.controller import AdbController
    from maa.define import MaaAdbInputMethodEnum, MaaAdbScreencapMethodEnum

    return AdbController(
        adb_path, serial,
        screencap_methods=MaaAdbScreencapMethodEnum.Default,
        # Both support real down/move/up. Do not silently select AdbShell, whose
        # click/swipe-only behavior cannot implement drag gestures.
        input_methods=MaaAdbInputMethodEnum.Maatouch | MaaAdbInputMethodEnum.MinitouchAndAdbKey,
    )


def check_android_input(adb_path: str, serial: str) -> None:
    """MaaTouch may report success even when Android rejects input injection.

    KEYCODE_UNKNOWN has no visible action; the check runs before a task sends any input.
    """
    try:
        result = subprocess.run([adb_path, "-s", serial, "shell", "input", "keyevent", "0"],
                                capture_output=True, text=True, encoding="utf-8", errors="replace",
                                timeout=5, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise RuntimeError(f"无法确认 Android 输入权限：{error}") from error
    detail = (result.stdout + "\n" + result.stderr).strip()
    if "INJECT_EVENTS" in detail or "SecurityException" in detail:
        raise RuntimeError(ANDROID_INPUT_DENIED)
    if result.returncode:
        raise RuntimeError(f"无法确认 Android 输入权限：{detail[:2000] or 'ADB 命令失败'}")


# Compatibility for existing plugins and replay tests. iOS devices use this bridge controller;
# Android devices use make_android_controller.
IPhoneController = DeviceController
