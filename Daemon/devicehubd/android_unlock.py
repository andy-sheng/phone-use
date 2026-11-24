"""System keyguard checks. Only fixed, non-secret arguments are passed to ADB."""
import re
import subprocess

from devicehubd.android_ui import DUMP_COMMAND, hierarchy_root
from devicehubd.protocol import RpcError


def shell(adb, serial, *args, tty=False):
    command = [adb, "-s", serial, "shell"]
    if tty:
        command.append("-tt")
    try:
        result = subprocess.run(command + list(args), capture_output=True,
                                timeout=6, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise RpcError("unlockUnavailable", "Cannot query the Android lock screen") from None
    if result.returncode:
        raise RpcError("unlockUnavailable", "Android lock screen command unavailable")
    return result.stdout.decode("utf-8", errors="replace")


def identity(adb, serial):
    # Emulator port numbers and wireless debugging addresses can be reassigned to other devices.
    return parse_identity(shell(adb, serial, "settings", "get", "secure", "android_id"))


def parse_identity(output):
    value = output.strip()
    if not re.fullmatch(r"[0-9a-fA-F]{1,16}", value):
        raise RpcError("unlockUnavailable", "Cannot identify this Android user for credential storage")
    return value.lower().zfill(16)


def locked(adb, serial):
    return parse_keyguard(shell(adb, serial, "dumpsys", "window", "policy"))


def parse_keyguard(dump):
    section = re.search(r"(?m)^\s*KeyguardServiceDelegate[^\n]*\n((?:[ \t]+[^\n]*\n?)*)", dump)
    states = re.findall(r"(?m)^\s*showing=(true|false)\s*$", section[1]) if section else []
    if len(states) != 1:
        raise RpcError("unlockUnavailable", "Android did not report the keyguard state")
    return states[0] == "true"


def pin_prompt_visible(adb, serial):
    """SystemUI's lightweight bouncer flag, when the device exposes it."""
    try:
        dump = shell(adb, serial, "dumpsys", "activity", "service", "com.android.systemui/.SystemUIService", "SysUiState")
    except RpcError:
        return False
    flags = re.search(r"(?m)^[ \t]*mSysUiStateFlags=\d+[ \t]*\n[ \t]*([a-z0-9_|]+)[ \t]*$", dump)
    return bool(flags and "bouncer_visible" in flags[1].split("|"))


def pin_keys(dump, *, filled=False):
    """Pixel centers from a single SystemUI layout. Require an empty entry before typing."""
    root = hierarchy_root(dump)
    if root is None:
        return None
    prefix = "com.android.systemui:id/"
    keys = {}
    entries = []
    for node in root.iter("node"):
        if node.get("package") != "com.android.systemui" or node.get("enabled") != "true":
            continue
        resource = node.get("resource-id", "")
        if not resource.startswith(prefix):
            continue
        name = resource[len(prefix):]
        if name == "pinEntry":
            entries.append(node)
        if not re.fullmatch(r"key[0-9]", name):
            continue
        bounds = re.fullmatch(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", node.get("bounds", ""))
        if not bounds:
            return None
        left, top, right, bottom = map(int, bounds.groups())
        if right <= left or bottom <= top:
            return None
        # Some keyboards shuffle digits. Prefer the displayed digit over the view's slot.
        labels = [node.get("content-desc", ""), node.get("text", "")]
        labels.extend(child.get("text", "") for child in node.iter("node")
                      if child.get("resource-id") == prefix + "digit_text")
        labels = {label for label in labels if re.fullmatch("[0-9]", label)}
        if len(labels) > 1:
            return None
        digit = next(iter(labels), name[-1])
        if digit in keys:
            return None
        keys[digit] = ((left + right) // 2, (top + bottom) // 2)
    if len(entries) != 1 or entries[0].get("password") != "true" or entries[0].get("text") is None:
        return None
    if bool(entries[0].get("text")) != filled or len(keys) != 10 or len(set(keys.values())) != 10:
        return None
    return keys


def read_pin_keys(adb, serial, *, filled=False):
    # /dev/tty returns XML over ADB without leaving a UI dump on device storage.
    dump = shell(adb, serial, *DUMP_COMMAND, tty=True)
    return pin_keys(dump, filled=filled)
