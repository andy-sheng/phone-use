"""Read the default display's live geometry without transferring a screenshot."""

from dataclasses import dataclass
import re
import subprocess

from devicehubd.protocol import RpcError


@dataclass(frozen=True)
class DisplayGeometry:
    width: int
    height: int
    rotation: int


def parse_display_geometry(output: str) -> DisplayGeometry:
    for line in output.splitlines():
        if "Viewport" not in line or not re.search(r"\bdisplayId=0(?!\d)", line):
            continue
        if re.search(r"\bisActive=(?:false|\[0\])", line):
            continue
        orientation = re.search(r"\borientation=([0-3])\b", line)
        frame = re.search(r"\blogicalFrame=\[\s*(-?\d+),\s*(-?\d+),\s*(-?\d+),\s*(-?\d+)\s*\]", line)
        if orientation and frame:
            left, top, right, bottom = map(int, frame.groups())
            if right > left and bottom > top:
                return DisplayGeometry(right - left, bottom - top, int(orientation[1]))
    raise RpcError("displayCheckFailed", "Cannot read Android's default display geometry; no input was sent")


def read_display_geometry(adb_path: str, serial: str) -> DisplayGeometry:
    try:
        result = subprocess.run(
            [adb_path, "-s", serial, "shell", "dumpsys", "input"],
            capture_output=True, text=True, encoding="utf-8", errors="replace",
            timeout=2, check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise RpcError("displayCheckFailed", f"Cannot verify Android display geometry: {error}") from error
    if result.returncode:
        detail = (result.stderr or result.stdout).strip()[:1000]
        raise RpcError("displayCheckFailed", f"Cannot verify Android display geometry: {detail or 'ADB command failed'}")
    return parse_display_geometry(result.stdout)
