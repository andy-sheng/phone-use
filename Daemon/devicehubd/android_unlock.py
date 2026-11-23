"""System keyguard checks. Only fixed, non-secret arguments are passed to ADB."""
import re
import subprocess
import xml.etree.ElementTree as ET

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
    value = shell(adb, serial, "settings", "get", "secure", "android_id").strip()
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


def system_pin_pad(dump, *, empty=False, filled=False):
    start, end = dump.find("<hierarchy"), dump.find("</hierarchy>")
    if start < 0 or end < start:
        return False
    try:
        root = ET.fromstring(dump[start:end + len("</hierarchy>")])
    except ET.ParseError:
        return False
    ids = {node.get("resource-id"): node for node in root.iter("node")
           if node.get("package") == "com.android.systemui" and node.get("enabled") == "true"}
    prefix = "com.android.systemui:id/"
    entry = ids.get(prefix + "pinEntry")
    return (entry is not None and entry.get("password") == "true" and (not empty or entry.get("text") == "")
            and (not filled or bool(entry.get("text")))
            and all(prefix + "key" + str(i) in ids for i in range(10)))


def ready_for_pin(adb, serial):
    # /dev/tty returns XML over ADB without leaving a UI dump on device storage.
    return system_pin_pad(shell(adb, serial, "uiautomator", "dump", "/dev/tty", tty=True), empty=True) and locked(adb, serial)


def system_pin_pad_present(adb, serial, *, filled=False):
    return system_pin_pad(shell(adb, serial, "uiautomator", "dump", "/dev/tty", tty=True), filled=filled) and locked(adb, serial)
