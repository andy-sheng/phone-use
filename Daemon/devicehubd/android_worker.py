"""One serialized Maa ADB controller per device, with native-pixel screenshot geometry."""

import argparse
import asyncio
import base64
import contextlib
import io
import logging
import math
import os
import re
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any

from devicehubd import protocol
from devicehubd.android_display import read_display_geometry
from devicehubd.android_video import AndroidVideoManager
from devicehubd.protocol import RpcError

logger = logging.getLogger("devicehubd.android")
KEYS = {"home": 3, "back": 4, "volume_up": 24, "volume_down": 25, "lock": 26, "app_switch": 187}


def check_input_permission(adb_path: str, serial: str) -> None:
    """MaaTouch may report success even when the OS rejects input injection.

    KEYCODE_UNKNOWN has no visible action. Run this only when the caller first
    requests input, so connecting, screenshots and app launches stay independent
    of permission to inject touch/key events.
    """
    try:
        result = subprocess.run(
            [adb_path, "-s", serial, "shell", "input", "keyevent", "0"],
            capture_output=True, text=True, encoding="utf-8", errors="replace",
            timeout=5, check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise RpcError("inputCheckFailed", f"Cannot verify Android input permission: {error}") from error
    detail = (result.stdout + "\n" + result.stderr).strip()
    if "INJECT_EVENTS" in detail or "SecurityException" in detail:
        raise RpcError(
            "inputNotAllowed",
            "Android 拒绝注入触摸或按键。请在开发者选项中开启“USB 调试（安全设置）”"
            "（小米/红米等设备需单独开启），完成手机上的确认后重试；如系统要求，请重启手机。",
        )
    if result.returncode:
        raise RpcError("inputCheckFailed", f"Cannot verify Android input permission: {detail[:2000] or 'ADB command failed'}")


def make_controller(adb_path: str, serial: str):
    # Lazy imports keep iOS discovery independent of the Android native runtime.
    from maa.controller import AdbController
    from maa.define import LoggingLevelEnum, MaaAdbInputMethodEnum, MaaAdbScreencapMethodEnum
    from maa.tasker import Tasker

    Tasker.set_stdout_level(LoggingLevelEnum.Off)
    log_dir = Path(os.environ.get("DEVICEHUB_LOG_DIR", str(Path.home() / "Library/Logs/DeviceHub")))
    log_dir.mkdir(parents=True, exist_ok=True)
    Tasker.set_log_dir(log_dir)
    return AdbController(
        adb_path, serial,
        screencap_methods=MaaAdbScreencapMethodEnum.Default,
        # Both support real down/move/up. Do not silently select AdbShell, whose
        # click/swipe-only behavior cannot implement the interactive drag contract.
        input_methods=MaaAdbInputMethodEnum.Maatouch | MaaAdbInputMethodEnum.MinitouchAndAdbKey,
    )


class AndroidDevice:
    """The GUI preview and automation share this controller through separate sessions.

    Each request carries the sending session's ``owner``. A touch held by one owner can
    only be moved or lifted by that owner; internal cleanup (rotation, close) lifts it
    regardless. Keys are held only within a single command, so they have no owner.
    """

    def __init__(self, adb_path: str, serial: str, *, controller_factory=make_controller,
                 permission_checker=check_input_permission,
                 geometry_reader=read_display_geometry,
                 stopped: threading.Event | None = None) -> None:
        self.adb_path, self.serial = adb_path, serial
        self._factory = controller_factory
        self._permission_checker = permission_checker
        self._geometry_reader = geometry_reader
        self._rotation: int | None = None
        self._input_checked = False
        self.stopped = stopped or threading.Event()
        self.controller = None
        self.width = self.height = 0
        self.held = False
        self.touch_owner: str | None = None
        self.held_keys: set[int] = set()
        self.geometry_changed = False
        self.failed = False

    def _wait(self, job, operation: str, *, timeout: float = 30, cleanup: bool = False):
        deadline = time.monotonic() + timeout
        while not job.done:
            if not cleanup and self.stopped.is_set():
                raise RpcError("disconnected", "The Android session is closing")
            if time.monotonic() >= deadline:
                self.failed = True
                raise RpcError("timeout", f"Android {operation} timed out; reopen the device before retrying")
            time.sleep(0.01)
        if not job.succeeded:
            raise RpcError("androidCommandFailed", f"Android {operation} failed; the action was not replayed")
        return job

    def start(self) -> dict[str, Any]:
        self.controller = self._factory(self.adb_path, self.serial)
        if not self.controller.set_screenshot_use_raw_size(True):
            raise RpcError("androidConfigurationFailed", "Maa could not enable native-resolution screenshots")
        self._wait(self.controller.post_connection(), "connection (MaaTouch/minitouch required)", timeout=70)
        self._capture(initial=True)
        self._check_geometry()
        return {"services": [], "display": {"pixelWidth": self.width, "pixelHeight": self.height, "pointScale": 1}}

    def _capture(self, *, initial: bool = False):
        job = self._wait(self.controller.post_screencap(), "screenshot")
        image = job.get()
        if image is None or len(image.shape) != 3 or image.shape[2] != 3:
            raise RpcError("invalidScreenshot", "Maa did not return a BGR screenshot")
        height, width = image.shape[:2]
        native = tuple(self.controller.resolution)
        if width <= 0 or height <= 0 or native != (width, height):
            raise RpcError("invalidScreenshot", "Screenshot dimensions do not match the native display")
        if initial:
            self.width, self.height = width, height
        # Screenshots validate their own dimensions. Coordinate-bearing input
        # separately checks live display metadata, including 180-degree turns.
        elif self.geometry_changed or (width, height) != (self.width, self.height):
            self.geometry_changed = True
            with contextlib.suppress(Exception):
                self.release()
            raise RpcError("displayChanged", "Android screen size or orientation changed; close and reopen the device")
        return image

    @staticmethod
    def _number(params: dict[str, str], key: str, minimum: float, maximum: float,
                default: str | None = None) -> float:
        value = params.get(key, default)
        try:
            number = float(value) if isinstance(value, str) else math.nan
        except ValueError:
            number = math.nan
        if not math.isfinite(number) or not minimum <= number <= maximum:
            raise RpcError("invalidParams", f"{key} must be a string number in [{minimum}, {maximum}]")
        return number

    def _point(self, params: dict[str, str], x: str = "x", y: str = "y") -> tuple[int, int]:
        nx = self._number(params, x, 0, 1)
        ny = self._number(params, y, 0, 1)
        # Swift uses pixel / dimension; preserve those pixels and clamp the 1.0 edge.
        return min(round(nx * self.width), self.width - 1), min(round(ny * self.height), self.height - 1)

    def _idle_touch(self) -> None:
        if self.held:
            raise RpcError("invalidState", "A touch is already held; release it before starting another gesture")

    def _check_input(self) -> None:
        if not self._input_checked:
            self._permission_checker(self.adb_path, self.serial)
            # Failed checks are deliberately not cached: the user can grant the
            # device-side permission and retry in this same connected session.
            self._input_checked = True
        if self.stopped.is_set():
            raise RpcError("disconnected", "The Android session is closing")

    def _check_geometry(self) -> None:
        # Maa's cached resolution only changes after a screenshot. A screenshot
        # on some phones takes over a second, stretching each drag into a long
        # press. Read live input-display metadata instead, including rotation.
        geometry = self._geometry_reader(self.adb_path, self.serial)
        if (self.geometry_changed or (geometry.width, geometry.height) != (self.width, self.height)
                or self._rotation is not None and geometry.rotation != self._rotation):
            self.geometry_changed = True
            raise RpcError("displayChanged", "Android screen size or orientation changed; close and reopen the device")
        self._rotation = geometry.rotation

    def _prepare_input(self) -> None:
        self._check_geometry()
        self._check_input()

    def release(self, owner: str | None = None) -> None:
        """Without an owner (internal cleanup), lifts any held touch."""
        if self.controller is None:
            return
        if self.held and (owner is None or self.touch_owner in (None, owner)):
            self._wait(self.controller.post_touch_up(), "touch release", timeout=2, cleanup=True)
            self.held, self.touch_owner = False, None
        for key in list(self.held_keys):
            self._wait(self.controller.post_key_up(key), "key release", timeout=2, cleanup=True)
            self.held_keys.remove(key)

    def command(self, params: dict[str, str]) -> dict[str, Any]:
        if not isinstance(params, dict) or any(not isinstance(v, str) for v in params.values()):
            raise RpcError("invalidParams", "Android command parameters must be strings")
        action = params.get("action")
        owner = params.get("owner", "")
        if action == "release":
            self.release(owner)
            return {}
        if self.controller is None or self.stopped.is_set():
            raise RpcError("disconnected", "The Android session is closed")
        if self.failed:
            raise RpcError("invalidState", "An Android operation timed out; close and reopen the device")
        handler = {
            "screenshot": self._screenshot, "touch": self._touch, "tap": self._tap,
            "swipe": self._swipe, "press": self._press, "launch": self._launch,
        }.get(action)
        if handler is None:
            raise RpcError("unknownMethod", f"Unknown Android action: {action}")
        try:
            return handler(params, owner) or {}
        except Exception:
            # Never replay a failed action. Only best-effort release of this owner's input is safe.
            with contextlib.suppress(Exception):
                self.release(owner)
            raise

    def _screenshot(self, params: dict[str, str], owner: str) -> dict[str, Any]:
        from PIL import Image

        image = self._capture()
        buffer = io.BytesIO()
        Image.fromarray(image[:, :, ::-1]).save(buffer, format="PNG")
        return {"png": base64.b64encode(buffer.getvalue()).decode("ascii"),
                "width": self.width, "height": self.height}

    def _touch(self, params: dict[str, str], owner: str) -> None:
        phase = params.get("phase")
        if phase == "ended":
            self.release(owner)
            return
        if phase not in {"began", "moved"}:
            raise RpcError("invalidParams", "Touch phase must be began, moved or ended")
        point = self._point(params)
        if phase == "began":
            self._idle_touch()
        elif not self.held:
            raise RpcError("invalidState", "No touch is held")
        elif self.touch_owner not in (None, owner):
            raise RpcError("invalidState", "The held touch belongs to another session")
        self._prepare_input()
        if phase == "began":
            self.held, self.touch_owner = True, owner  # Also released when the operation reports failure.
            self._wait(self.controller.post_touch_down(*point), "touch began")
        else:
            self._wait(self.controller.post_touch_move(*point), "touch moved")

    @contextlib.contextmanager
    def _momentary_touch(self, owner: str):
        """Holds the contact for one controller job; on failure it stays held for command() to release."""
        self._idle_touch()
        self._prepare_input()
        self.held, self.touch_owner = True, owner
        yield
        self.held, self.touch_owner = False, None

    def _tap(self, params: dict[str, str], owner: str) -> None:
        point = self._point(params)
        with self._momentary_touch(owner):
            self._wait(self.controller.post_click(*point), "tap")

    def _swipe(self, params: dict[str, str], owner: str) -> None:
        start = self._point(params, "fromX", "fromY")
        end = self._point(params, "toX", "toY")
        duration = round(self._number(params, "durationMs", 1, 30_000, "300"))
        with self._momentary_touch(owner):
            self._wait(self.controller.post_swipe(*start, *end, duration), "swipe", timeout=duration / 1000 + 30)

    def _press(self, params: dict[str, str], owner: str) -> None:
        key = KEYS.get(params.get("button", ""))
        if key is None:
            raise RpcError("unsupported", "Unsupported Android hardware button")
        duration = self._number(params, "durationMs", 1, 30_000) if "durationMs" in params else None
        self._check_input()
        if duration is None:
            self._wait(self.controller.post_click_key(key), "key press")
            return
        self.held_keys.add(key)
        self._wait(self.controller.post_key_down(key), "key down")
        if self.stopped.wait(duration / 1000):
            raise RpcError("disconnected", "The Android session is closing")
        self._wait(self.controller.post_key_up(key), "key up")
        self.held_keys.remove(key)

    def _launch(self, params: dict[str, str], owner: str) -> None:
        bundle = params.get("bundleID", "")
        if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.]*(?:/[A-Za-z0-9_.]+)?", bundle):
            raise RpcError("invalidParams", "bundleID must be an Android package name or package/activity")
        self._wait(self.controller.post_start_app(bundle), "launch")

    def close(self) -> None:
        with contextlib.suppress(Exception):
            self.release()
        self.controller = None


async def run(adb_path: str, serial: str, out: Any) -> int:
    stopped = threading.Event()
    device = AndroidDevice(adb_path, serial, stopped=stopped)
    video = AndroidVideoManager(adb_path, serial)
    video_operation = None
    video_closing = None
    messages: asyncio.Queue = asyncio.Queue()
    loop = asyncio.get_running_loop()
    reader = asyncio.StreamReader()
    await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), sys.stdin)

    def stop() -> None:
        nonlocal video_closing
        stopped.set()
        messages.put_nowait(None)
        if video_operation is not None:
            video_operation.cancel()
        if video_closing is None:
            # Start video teardown immediately, even if a Maa/ADB input call is
            # still returning in its thread. Video owns no Maa controller state.
            video_closing = asyncio.create_task(video.close())

    async def read() -> None:
        try:
            while line := await reader.readline():
                try:
                    messages.put_nowait(protocol.decode(line))
                except ValueError:
                    continue
        finally:
            stop()

    def emit(message: dict[str, Any]) -> None:
        out.write(protocol.encode(message))
        out.flush()

    for signum in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(signum, stop)
    reading = asyncio.create_task(read())
    try:
        info = await asyncio.to_thread(device.start)
        emit({"event": "ready", **info})
        while not stopped.is_set():
            message = await messages.get()
            if message is None or stopped.is_set():
                break
            try:
                method = message.get("method")
                params = message.get("params") or {}
                if method == "androidCommand":
                    result = await asyncio.to_thread(device.command, params)
                elif method in {"startAndroidVideo", "stopAndroidVideo"}:
                    operation = video.start() if method == "startAndroidVideo" else video.stop(params.get("token"))
                    video_operation = asyncio.create_task(operation)
                    try:
                        result = await video_operation
                    finally:
                        video_operation = None
                else:
                    raise RpcError("unknownMethod", f"Unknown Android worker method: {method}")
                emit({"id": message.get("id"), "result": result})
            except asyncio.CancelledError:
                if stopped.is_set():
                    break
                raise
            except RpcError as error:
                emit({"id": message.get("id"), "error": error.to_json()})
            except Exception as error:
                logger.exception("Android command failed")
                emit({"id": message.get("id"), "error": {"code": "androidCommandFailed", "message": str(error)}})
        return 0
    except Exception as error:
        detail = error.to_json() if isinstance(error, RpcError) else {"code": "androidConnectionFailed", "message": str(error)}
        emit({"event": "failed", "error": detail})
        return 1
    finally:
        stopped.set()
        reading.cancel()
        await video.close()
        if video_closing is not None:
            await video_closing
        await asyncio.to_thread(device.close)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--adb", required=True)
    parser.add_argument("--serial", required=True)
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="[android worker] %(levelname)s %(message)s")
    # Native libraries may write directly to fd 1; preserve a private protocol fd
    # before loading Maa and redirect every other stdout write to stderr.
    out = os.fdopen(os.dup(sys.stdout.fileno()), "wb", buffering=0)
    os.dup2(sys.stderr.fileno(), sys.stdout.fileno())
    code = asyncio.run(run(args.adb, args.serial, out))
    os._exit(code)


if __name__ == "__main__":
    main()
