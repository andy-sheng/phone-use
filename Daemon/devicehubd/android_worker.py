"""One serialized Android device per worker: scrcpy input plus native-pixel screenshots."""

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
import uuid
from typing import Any

from devicehubd import android_unlock, protocol
from devicehubd.android_control import ACTION_DOWN, ACTION_MOVE, ACTION_UP, KEY_DOWN, KEY_UP, AdbDriver
from devicehubd.android_display import read_display_geometry
from devicehubd.android_rotation import AndroidRotation
from devicehubd.android_video import AndroidVideoManager
from devicehubd.keyboard import preview_keys
from devicehubd.lifetime import WORKER_EXIT_DEADLINE, exit_after
from devicehubd.protocol import RpcError

logger = logging.getLogger("devicehubd.android")
KEYS = {"home": 3, "back": 4, "volume_up": 24, "volume_down": 25, "lock": 26, "app_switch": 187}
# USB HID usage -> Android KeyEvent.KEYCODE_* on the US keyboard.
KEYBOARD_CODES = {
    **{usage: 29 + usage - 4 for usage in range(4, 30)},   # A–Z
    **{usage: 8 + usage - 30 for usage in range(30, 39)},  # 1–9
    39: 7, 40: 66, 41: 111, 42: 67, 43: 61, 44: 62,      # 0, Enter, Escape, Backspace, Tab, Space
    45: 69, 46: 70, 47: 71, 48: 72, 49: 73, 51: 74, 52: 75, 53: 68, 54: 55, 55: 56, 56: 76,
    74: 122, 75: 92, 76: 112, 77: 123, 78: 93, 79: 22, 80: 21, 81: 20, 82: 19,
}
TAP_HOLD = 0.05
SWIPE_STEP = 0.01
INPUT_START_WAIT = 20


def check_input_permission(adb_path: str, serial: str) -> None:
    """Injection is unacknowledged, so a denied INJECT_EVENTS permission would fail silently.

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


class AndroidDevice:
    """The GUI preview and other sessions share this device through separate owners.

    Each request carries the sending session's ``owner``. A touch held by one owner can
    only be moved or lifted by that owner; internal cleanup (rotation, close) lifts it
    regardless. Keys are held only within a single command, so they have no owner.
    """

    def __init__(self, adb_path: str, serial: str, *, driver_factory=AdbDriver,
                 permission_checker=check_input_permission,
                 geometry_reader=read_display_geometry,
                 stopped: threading.Event | None = None,
                 tap_hold: float = TAP_HOLD, swipe_step: float = SWIPE_STEP) -> None:
        self.adb_path, self.serial = adb_path, serial
        self._factory = driver_factory
        self._permission_checker = permission_checker
        self._geometry_reader = geometry_reader
        self._tap_hold, self._swipe_step = tap_hold, swipe_step
        self._rotation: int | None = None
        self.rotation_control = AndroidRotation(adb_path, serial)
        self.geometry_id = uuid.uuid4().hex
        self._requires_geometry_id = False
        self._input_checked = False
        self._input_starting: threading.Thread | None = None
        self.stopped = stopped or threading.Event()
        self.driver = None
        self.width = self.height = 0
        self.held = False
        self.touch_owner: str | None = None
        self.touch_point: tuple[int, int] = (0, 0)
        self.held_keys: set[int] = set()
        self.geometry_changed = False
        self.failed = False

    def start(self) -> dict[str, Any]:
        self.driver = self._factory(self.adb_path, self.serial)
        geometry = self._geometry_reader(self.adb_path, self.serial, allow_inactive=True)
        self.physical_id = geometry.physical_id
        self.width, self.height, self._rotation = geometry.width, geometry.height, geometry.rotation
        # A sleeping display has no live frame. Open from its viewport so prepareUnlock can wake it.
        if geometry.active:
            self._capture()
            self._check_geometry()
        # Start the input channel now so the first touch does not wait for it. Its failure only
        # surfaces when input is requested; screenshots and launches never need it.
        self._input_starting = threading.Thread(target=self._start_input_quietly, name="android-input-start",
                                                daemon=True)
        self._input_starting.start()
        return {"services": [], "display": self.display_info()}

    def display_info(self):
        return {"pixelWidth": self.width, "pixelHeight": self.height, "pointScale": 1,
                "androidRotation": self._rotation, "geometryID": self.geometry_id}

    def _adopt_geometry(self, geometry):
        self.physical_id = geometry.physical_id
        self.width, self.height, self._rotation = geometry.width, geometry.height, geometry.rotation
        self.geometry_changed = False
        self._requires_geometry_id = True
        self.geometry_id = uuid.uuid4().hex
        return {"display": self.display_info()}

    def _rotate(self, params, owner):
        direction = params.get("direction")
        if direction not in ("left", "right") or not owner:
            raise RpcError("invalidParams", "Rotation requires an owner and a left or right direction")
        self.release(owner)
        self._idle_touch()
        self._check_geometry()
        # Android ROTATION_90 is the device turned counterclockwise from its natural orientation.
        target = (self._rotation + (1 if direction == "left" else -1)) % 4
        geometry = self.rotation_control.turn(owner, target, lambda: self._geometry_reader(self.adb_path, self.serial))
        return self._adopt_geometry(geometry)

    def _restore_rotation(self, params, owner):
        if owner and self.rotation_control.restore(owner):
            self.geometry_changed = True
            # WindowManager applies restored sensor/app preferences asynchronously.
            # Wait for a stable viewport before advertising geometry to the next preview.
            geometry = self._geometry_reader(self.adb_path, self.serial)
            for _ in range(8):
                time.sleep(0.12)
                next_geometry = self._geometry_reader(self.adb_path, self.serial)
                if next_geometry == geometry:
                    return self._adopt_geometry(geometry)
                geometry = next_geometry
            raise RpcError("displayChanged", "Android display is still changing; reconnect the preview")
        return {}

    def _start_input_quietly(self) -> None:
        try:
            self.driver.start_input()
        except Exception as error:
            logger.info("Android input channel will retry on first input: %s", error)

    def _call(self, operation, *args):
        try:
            return operation(*args)
        except RpcError as error:
            if error.code == "timeout":
                self.failed = True
            raise

    def _capture(self):
        image = self._call(self.driver.capture, self.physical_id)
        width, height = image.size
        if width <= 0 or height <= 0:
            raise RpcError("invalidScreenshot", "Screenshot dimensions do not match the native display")
        # Screenshots validate their own dimensions. Coordinate-bearing input
        # separately checks live display metadata, including 180-degree turns.
        if self.geometry_changed or (width, height) != (self.width, self.height):
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
        starting, self._input_starting = self._input_starting, None
        if starting is not None:
            starting.join(INPUT_START_WAIT)
        # Restarts a channel that failed to start or ended since.
        self.driver.start_input()
        if self.stopped.is_set():
            raise RpcError("disconnected", "The Android session is closing")

    def _check_geometry(self) -> None:
        # A screenshot on some phones takes over a second, stretching each drag into a long
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

    def _send_touch(self, action: int, point: tuple[int, int]) -> None:
        self.touch_point = point
        self.driver.touch(action, *point, self.width, self.height)

    def release(self, owner: str | None = None) -> None:
        """Without an owner (internal cleanup), lifts any held touch."""
        if self.driver is None:
            return
        if self.held and (owner is None or self.touch_owner in (None, owner)):
            try:
                self.driver.touch(ACTION_UP, *self.touch_point, self.width, self.height)
            finally:
                # A failed lift means the channel is gone; the next input starts a new one.
                self.held, self.touch_owner = False, None
        for key in list(self.held_keys):
            try:
                self.driver.key(KEY_UP, key)
            finally:
                self.held_keys.discard(key)

    def command(self, params: dict[str, str]) -> dict[str, Any]:
        if not isinstance(params, dict) or any(not isinstance(v, str) for v in params.values()):
            raise RpcError("invalidParams", "Android command parameters must be strings")
        action = params.get("action")
        owner = params.get("owner", "")
        if action == "release":
            self.release(owner)
            return {}
        if self.driver is None or self.stopped.is_set():
            raise RpcError("disconnected", "The Android session is closed")
        if self.failed:
            raise RpcError("invalidState", "An Android operation timed out; close and reopen the device")
        if action in {"tap", "swipe", "screenshot", "rotate"} or action == "touch" and params.get("phase") != "ended":
            token = params.get("geometryID")
            if (token is not None or self._requires_geometry_id) and token != self.geometry_id:
                raise RpcError("displayChanged", "Android rotation changed; reconnect this device session")
        handler = {
            "unlockIdentity": self._unlock_identity, "prepareUnlock": self._prepare_unlock,
            "submitUnlockPIN": self._submit_unlock_pin,
            "screenshot": self._screenshot, "touch": self._touch, "tap": self._tap,
            "swipe": self._swipe, "press": self._press, "keyboardInput": self._keyboard_input, "launch": self._launch,
            "rotate": self._rotate, "restoreRotation": self._restore_rotation,
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

    def _unlock_identity(self, params, owner):
        return {"identity": android_unlock.identity(self.adb_path, self.serial)}

    def _prepare_unlock(self, params, owner):
        adb, serial = self.adb_path, self.serial
        self._idle_touch()
        stage = params.get("stage")
        if stage != "keypad":
            android_unlock.shell(adb, serial, "input", "keyevent", "KEYCODE_WAKEUP")
            if not android_unlock.locked(adb, serial):
                return {"status": "already_unlocked"}
            android_unlock.shell(adb, serial, "wm", "dismiss-keyguard")
            self._pause(0.5)
            if not android_unlock.locked(adb, serial):
                return {"status": "unlocked"}
            # Read the keypad after any Keychain approval so its positions are fresh.
            if stage == "wake":
                return {"status": "needs_saved_pin"}
        ready = android_unlock.read_pin_keys(adb, serial) and android_unlock.locked(adb, serial)
        return {"status": "needs_saved_pin" if ready else "needs_user_unlock"}

    def _submit_unlock_pin(self, params, owner):
        pin = params.get("pin", "")
        if not re.fullmatch(r"(?:[0-9]{4}|[0-9]{6})", pin):
            raise RpcError("invalidParams", "Expected a numeric device PIN")
        self._idle_touch()
        self._check_input()
        adb, serial = self.adb_path, self.serial
        if params.get("identity") != android_unlock.identity(adb, serial):
            return {"status": "needs_user_unlock"}
        tracks_prompt = android_unlock.pin_prompt_visible(adb, serial)
        keys = android_unlock.read_pin_keys(adb, serial)
        if not keys or any(x >= self.width or y >= self.height for x, y in keys.values()):
            return {"status": "needs_user_unlock"}

        for index, digit in enumerate(pin):
            if index:
                self._pause(0.025)
            if not android_unlock.locked(adb, serial):
                return {"status": "unlock_unconfirmed" if index else "already_unlocked"}
            if tracks_prompt:
                visible = android_unlock.pin_prompt_visible(adb, serial)
            else:
                # Older SystemUI builds may omit the flag. Verify the same pad before continuing.
                visible = index == 0 or android_unlock.read_pin_keys(adb, serial, filled=True) == keys
            if not visible:
                return {"status": "unlock_unconfirmed" if index else "needs_user_unlock"}
            with self._momentary_touch(owner, keys[digit]):
                self._pause(self._tap_hold)

        self._pause(0.5)
        if not android_unlock.locked(adb, serial):
            return {"status": "unlocked"}
        # Only send Enter if the system still shows a filled PIN field.
        if android_unlock.read_pin_keys(adb, serial, filled=True) and android_unlock.locked(adb, serial):
            self.held_keys.add(66)
            self.driver.key(KEY_DOWN, 66)
            self.driver.key(KEY_UP, 66)
            self.held_keys.discard(66)
        for _ in range(6):
            self._pause(0.25)
            if not android_unlock.locked(adb, serial):
                return {"status": "unlocked"}
        return {"status": "unlock_unconfirmed"}

    def _screenshot(self, params: dict[str, str], owner: str) -> dict[str, Any]:
        image = self._capture()
        buffer = io.BytesIO()
        image.save(buffer, format="PNG", compress_level=1)
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
            self._send_touch(ACTION_DOWN, point)
        else:
            self._send_touch(ACTION_MOVE, point)

    @contextlib.contextmanager
    def _momentary_touch(self, owner: str, start: tuple[int, int]):
        """Presses at ``start`` for one gesture; on failure it stays held for command() to release."""
        self._idle_touch()
        self._prepare_input()
        self.held, self.touch_owner = True, owner
        self._send_touch(ACTION_DOWN, start)
        yield
        self._send_touch(ACTION_UP, self.touch_point)
        self.held, self.touch_owner = False, None

    def _pause(self, seconds: float) -> None:
        if self.stopped.wait(seconds):
            raise RpcError("disconnected", "The Android session is closing")

    def _tap(self, params: dict[str, str], owner: str) -> None:
        point = self._point(params)
        with self._momentary_touch(owner, point):
            self._pause(self._tap_hold)

    def _swipe(self, params: dict[str, str], owner: str) -> None:
        start = self._point(params, "fromX", "fromY")
        end = self._point(params, "toX", "toY")
        duration = round(self._number(params, "durationMs", 1, 30_000, "300")) / 1000
        with self._momentary_touch(owner, start):
            if start == end:
                self._pause(duration)  # A swipe that does not move is a long press.
                return
            steps = max(1, round(duration / self._swipe_step))
            for index in range(1, steps + 1):
                self._pause(duration / steps)
                fraction = index / steps
                point = (round(start[0] + (end[0] - start[0]) * fraction),
                         round(start[1] + (end[1] - start[1]) * fraction))
                self._send_touch(ACTION_MOVE, point)

    def _press(self, params: dict[str, str], owner: str) -> None:
        key = KEYS.get(params.get("button", ""))
        if key is None:
            raise RpcError("unsupported", "Unsupported Android hardware button")
        duration = self._number(params, "durationMs", 1, 30_000) if "durationMs" in params else None
        self._check_input()
        self.held_keys.add(key)
        self.driver.key(KEY_DOWN, key)
        if duration is not None:
            self._pause(duration / 1000)
        self.driver.key(KEY_UP, key)
        self.held_keys.discard(key)

    def _keyboard_input(self, params, owner):
        strokes = preview_keys(params.get("keys"))
        self._check_input()
        for usage, shift in strokes:
            code = KEYBOARD_CODES[usage]
            meta = 0x41 if shift else 0  # META_SHIFT_ON | META_SHIFT_LEFT_ON
            self.held_keys.add(code)
            self.driver.key(KEY_DOWN, code, meta)
            self.driver.key(KEY_UP, code, meta)
            self.held_keys.discard(code)

    def _launch(self, params: dict[str, str], owner: str) -> None:
        bundle = params.get("bundleID", "")
        if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.]*(?:/[A-Za-z0-9_.]+)?", bundle):
            raise RpcError("invalidParams", "bundleID must be an Android package name or package/activity")
        self._call(self.driver.launch, bundle)

    def close(self) -> None:
        with contextlib.suppress(Exception):
            self.release()
        try:
            self.rotation_control.restore()
        except RpcError as error:
            logger.warning("Could not restore Android rotation: %s", error)
        driver, self.driver = self.driver, None
        if driver is not None:
            with contextlib.suppress(Exception):
                driver.close()


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
            # Start video teardown immediately, even if an ADB input call is
            # still returning in its thread. Video owns no input state.
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
        # The supervisor escalates to SIGKILL on its own; this covers a supervisor that is already gone.
        exit_after(WORKER_EXIT_DEADLINE)
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
    # Child processes and libraries may write directly to fd 1; preserve a private
    # protocol fd and redirect every other stdout write to stderr.
    out = os.fdopen(os.dup(sys.stdout.fileno()), "wb", buffering=0)
    os.dup2(sys.stderr.fileno(), sys.stdout.fileno())
    # Skip asyncio.run teardown: it would wait for an ADB call still blocked in an executor thread.
    code = asyncio.Runner().run(run(args.adb, args.serial, out))
    os._exit(code)


if __name__ == "__main__":
    main()
