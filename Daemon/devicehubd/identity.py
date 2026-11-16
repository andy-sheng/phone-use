"""The identity of the app that launched this daemon.

Apps built on PhoneUseKit pass it through the environment (``PhoneUseConfiguration.environment``)
so that each keeps its own socket, device cache, logs and pairing name. Without it the daemon
uses phone-use's identity and the DeviceHub locations existing installs already have.
"""

import os
from pathlib import Path


def home() -> Path:
    override = os.environ.get("DEVICEHUB_HOME")
    if override:
        return Path(override)
    return Path.home() / "Library" / "Application Support" / "DeviceHub"


def log_directory() -> Path:
    override = os.environ.get("DEVICEHUB_LOG_DIR")
    if override:
        return Path(override)
    if os.environ.get("DEVICEHUB_HOME"):
        return home() / "Logs"
    return Path.home() / "Library" / "Logs" / "DeviceHub"


def display_name() -> str:
    return os.environ.get("DEVICEHUB_DISPLAY_NAME") or "PhoneUse"


def device_cache() -> Path:
    return home() / "devices.json"


def default_socket() -> Path:
    return home() / "devicehubd.sock"
