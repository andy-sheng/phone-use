import os
import unittest
from pathlib import Path
from unittest import mock

from devicehubd import identity

IDENTITY_VARIABLES = ("DEVICEHUB_HOME", "DEVICEHUB_LOG_DIR", "DEVICEHUB_DISPLAY_NAME")


def environment(**values):
    base = {key: value for key, value in os.environ.items() if key not in IDENTITY_VARIABLES}
    return mock.patch.dict(os.environ, {**base, **values}, clear=True)


class IdentityTests(unittest.TestCase):
    def test_defaults_keep_phone_use_locations(self):
        with environment():
            support = Path.home() / "Library" / "Application Support" / "DeviceHub"
            self.assertEqual(identity.home(), support)
            self.assertEqual(identity.default_socket(), support / "devicehubd.sock")
            self.assertEqual(identity.device_cache(), support / "devices.json")
            self.assertEqual(identity.log_directory(), Path.home() / "Library" / "Logs" / "DeviceHub")
            self.assertEqual(identity.display_name(), "phone-use")

    def test_launching_app_identity_moves_all_state(self):
        with environment(DEVICEHUB_HOME="/tmp/automation-home", DEVICEHUB_LOG_DIR="/tmp/automation-logs",
                         DEVICEHUB_DISPLAY_NAME="automation"):
            self.assertEqual(identity.default_socket(), Path("/tmp/automation-home/devicehubd.sock"))
            self.assertEqual(identity.device_cache(), Path("/tmp/automation-home/devices.json"))
            self.assertEqual(identity.log_directory(), Path("/tmp/automation-logs"))
            self.assertEqual(identity.display_name(), "automation")

    def test_home_without_log_directory_keeps_logs_beside_state(self):
        with environment(DEVICEHUB_HOME="/tmp/other-home"):
            self.assertEqual(identity.log_directory(), Path("/tmp/other-home/Logs"))


if __name__ == "__main__":
    unittest.main()
