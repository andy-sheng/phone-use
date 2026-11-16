"""iOS Simulator discovery through ``simctl``; importing this module never touches a simulator.

Only booted iOS/iPadOS simulators are published. Their record UDIDs carry a ``simulator:``
prefix so they can never collide with a physical device, and control happens in the client
process through CoreSimulator rather than through a daemon worker.
"""

import asyncio
import json
import os
import re
import shutil
from dataclasses import dataclass
from typing import Any

SIMULATOR = "simulator"
PREFIX = "simulator:"
_RUNTIME = re.compile(r"\.SimRuntime\.iOS-(\d+(?:-\d+)*)$")
_DEVICE_TYPE_PREFIX = "com.apple.CoreSimulator.SimDeviceType."


@dataclass(frozen=True)
class SimulatorAttachment:
    identifier: str
    name: str
    product_type: str | None
    product_version: str

    @property
    def udid(self) -> str:
        return PREFIX + self.identifier


def product_type(device_type: str | None) -> str | None:
    """``…SimDeviceType.iPhone-17-Pro`` -> ``iPhone 17 Pro``; keeps the iPad prefix for layout."""
    if not device_type or not device_type.startswith(_DEVICE_TYPE_PREFIX):
        return None
    words = [word for word in device_type[len(_DEVICE_TYPE_PREFIX):].split("-") if word]
    return " ".join(words) or None


def parse_devices(output: str) -> list[SimulatorAttachment]:
    """Parses ``simctl list devices -j``, keeping booted iOS and iPadOS simulators."""
    devices: dict[str, Any] = json.loads(output).get("devices") or {}
    attached = []
    for runtime, entries in devices.items():
        match = _RUNTIME.search(runtime)
        if match is None or not isinstance(entries, list):
            continue
        version = match.group(1).replace("-", ".")
        for entry in entries:
            if not isinstance(entry, dict) or entry.get("state") != "Booted":
                continue
            if entry.get("isAvailable") is False or not entry.get("udid"):
                continue
            attached.append(SimulatorAttachment(
                identifier=entry["udid"],
                name=entry.get("name") or entry["udid"],
                product_type=product_type(entry.get("deviceTypeIdentifier")),
                product_version=version,
            ))
    return attached


def find_xcrun() -> str | None:
    return shutil.which("xcrun") or ("/usr/bin/xcrun" if os.access("/usr/bin/xcrun", os.X_OK) else None)


class SimulatorDiscovery:
    """``simctl`` takes about half a second, so listings are reused for ``interval`` seconds."""

    def __init__(self, interval: float = 3.0) -> None:
        self.interval = interval
        self._last: list[SimulatorAttachment] = []
        self._listed_at: float | None = None

    async def attached(self) -> list[SimulatorAttachment]:
        now = asyncio.get_running_loop().time()
        if self._listed_at is not None and now - self._listed_at < self.interval:
            return self._last
        self._listed_at = now
        xcrun = find_xcrun()
        if xcrun is None:
            self._last = []
            return self._last
        output = await self.command(xcrun, "simctl", "list", "devices", "booted", "-j")
        self._last = parse_devices(output)
        return self._last

    @staticmethod
    async def command(*arguments: str, timeout: float = 10) -> str:
        process = await asyncio.create_subprocess_exec(
            *arguments, stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
        )
        try:
            stdout, stderr = await asyncio.wait_for(process.communicate(), timeout)
        except BaseException:
            if process.returncode is None:
                process.kill()
            await process.wait()
            raise
        if process.returncode:
            raise ConnectionError(stderr.decode("utf-8", errors="replace").strip() or "simctl failed")
        return stdout.decode("utf-8", errors="replace")
