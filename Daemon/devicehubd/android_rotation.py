"""Manual rotation of Android's default display for the lifetime of a preview."""

import subprocess
import time

from devicehubd.protocol import RpcError


class AndroidRotation:
    def __init__(self, adb_path, serial):
        self.adb_path, self.serial = adb_path, serial
        self.original = None
        self.owner = None

    def _shell(self, *args):
        try:
            result = subprocess.run([self.adb_path, "-s", self.serial, "shell", *args],
                                    capture_output=True, text=True, timeout=3, check=False)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise RpcError("rotationFailed", f"Android rotation failed: {error}") from error
        output = (result.stdout + result.stderr).strip()
        if result.returncode or any(word in output.lower() for word in ("error", "exception", "unknown command")):
            raise RpcError("rotationFailed", output[:500] or "Android rejected the rotation command")
        return output

    def _policy(self):
        mode = self._shell("wm", "user-rotation").split()
        fixed = self._shell("wm", "fixed-to-user-rotation")
        if mode == ["free"]:
            angle = self._shell("settings", "get", "system", "user_rotation")
        elif len(mode) == 2 and mode[0] == "lock":
            angle = mode[1]
        else:
            raise RpcError("rotationFailed", "Android did not report its rotation policy")
        if angle not in ("0", "1", "2", "3", "null") or fixed not in (
                "default", "enabled", "disabled", "enabled_if_no_auto_rotation"):
            raise RpcError("rotationFailed", "Android reported an unsupported rotation policy")
        return mode[0], angle, fixed

    def _apply_policy(self, policy):
        mode, angle, fixed = policy
        if angle != "null":
            self._shell("wm", "user-rotation", "lock", angle)
        self._shell("wm", "fixed-to-user-rotation", fixed)
        if mode == "free":
            self._shell("wm", "user-rotation", "free")
            if angle == "null":
                self._shell("settings", "delete", "system", "user_rotation")

    def turn(self, owner, target, read_geometry):
        if self.owner is not None and self.owner != owner:
            raise RpcError("invalidState", "Another preview is controlling Android rotation")
        previous = self._policy()
        first_turn = self.original is None
        if first_turn:
            self.original, self.owner = previous, owner
        try:
            self._shell("wm", "user-rotation", "lock", str(target))
            # Launchers and the lock screen commonly pin the activity to portrait.
            self._shell("wm", "fixed-to-user-rotation", "enabled")
            deadline = time.monotonic() + 3
            while True:
                geometry = read_geometry()
                if geometry.rotation == target:
                    return geometry
                if time.monotonic() >= deadline:
                    raise RpcError("rotationFailed", "Android did not switch to the requested orientation")
                time.sleep(0.08)
        except Exception:
            self._apply_policy(previous)
            if first_turn:
                self.original = self.owner = None
            raise

    def restore(self, owner=None):
        if self.original is None or (owner is not None and self.owner != owner):
            return False
        self._apply_policy(self.original)
        self.original = self.owner = None
        return True
