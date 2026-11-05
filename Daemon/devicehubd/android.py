"""ADB discovery only; importing this module never loads Maa or changes a device."""

import asyncio
import os
import re
import shutil
from dataclasses import dataclass
from pathlib import Path


def android_assets_dir() -> Path | None:
    """The packaged app's ``Contents/Resources/android``; unset in development."""
    value = os.environ.get("DEVICEHUB_ANDROID_ASSETS")
    return Path(value).expanduser() if value else None


def find_adb() -> str | None:
    """An explicit override wins, including when it is invalid (do not silently switch servers).

    A user-installed adb is preferred over the bundled copy. adb clients kill a running
    server of a different version, so a bundled adb that differs from Android Studio's
    would repeatedly restart the user's server and drop every device connection.
    """
    override = os.environ.get("DEVICEHUB_ADB")
    if override:
        candidate = Path(override).expanduser()
        resolved = str(candidate) if candidate.is_file() else shutil.which(override)
        return resolved if resolved and os.access(resolved, os.X_OK) else None
    candidates = [shutil.which("adb")]
    for variable in ("ANDROID_HOME", "ANDROID_SDK_ROOT"):
        if os.environ.get(variable):
            candidates.append(str(Path(os.environ[variable]) / "platform-tools" / "adb"))
    candidates += [
        str(Path.home() / "Library/Android/sdk/platform-tools/adb"),
        str(Path.home() / "Android/Sdk/platform-tools/adb"),
        "/opt/homebrew/bin/adb", "/usr/local/bin/adb",
    ]
    if bundled := android_assets_dir():
        candidates.append(str(bundled / "platform-tools" / "adb"))
    return next((path for path in candidates if path and Path(path).is_file() and os.access(path, os.X_OK)), None)


@dataclass(frozen=True)
class AndroidAttachment:
    serial: str
    state: str
    connection: str
    name: str
    model: str | None = None

    @property
    def udid(self) -> str:
        return "android:" + self.serial


def parse_devices(output: str) -> list[AndroidAttachment]:
    devices = []
    for line in output.splitlines():
        line = line.strip()
        if not line or line.startswith(("List of devices", "*", "adb:")):
            continue
        fields = line.split()
        if len(fields) < 2:
            continue
        serial, state = fields[:2]
        # adb emits "no permissions (...)" as a multi-word state.
        if state == "no" and len(fields) > 2 and fields[2] == "permissions":
            state = "noPermissions"
        properties = dict(field.split(":", 1) for field in fields[2:] if ":" in field)
        model = properties.get("model")
        if serial.startswith("emulator-"):
            connection = "emulator"
        elif "usb" in properties:
            connection = "usb"
        elif re.search(r":\d+$", serial) or "._tcp" in serial:
            connection = "network"
        else:
            connection = "usb"
        devices.append(AndroidAttachment(serial, state, connection,
                                         (model or serial).replace("_", " "), model))
    return devices


class AndroidDiscovery:
    def __init__(self) -> None:
        self.adb_path: str | None = None

    async def attached(self) -> list[AndroidAttachment]:
        self.adb_path = find_adb()
        if self.adb_path is None:
            return []
        output = await self.command("devices", "-l")
        return parse_devices(output)

    async def command(self, *arguments: str, timeout: float = 8) -> str:
        if not self.adb_path:
            raise FileNotFoundError("ADB not found; install Android platform-tools or set DEVICEHUB_ADB")
        process = await asyncio.create_subprocess_exec(
            self.adb_path, *arguments, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
        )
        try:
            stdout, stderr = await asyncio.wait_for(process.communicate(), timeout)
        except BaseException:
            if process.returncode is None:
                process.kill()
            await process.wait()
            raise
        if process.returncode:
            raise ConnectionError(stderr.decode("utf-8", errors="replace").strip() or "ADB command failed")
        return stdout.decode("utf-8", errors="replace")

    async def version(self, serial: str) -> str | None:
        return (await self.command("-s", serial, "shell", "getprop", "ro.build.version.release")).strip() or None
