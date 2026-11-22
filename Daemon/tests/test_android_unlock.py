import unittest
from unittest.mock import Mock, patch

from devicehubd import android_unlock
from devicehubd.android_worker import AndroidDevice
from devicehubd.protocol import RpcError


class UnlockTests(unittest.TestCase):
    def test_android_keyguard_state_is_explicit(self):
        prefix = "DisplayPolicy\n  KeyguardServiceDelegate\n    showing="
        self.assertTrue(android_unlock.parse_keyguard(prefix + "true\n"))
        self.assertFalse(android_unlock.parse_keyguard(prefix + "false\n"))
        for missing in ["", "showing=false", prefix + "unknown\n"]:
            with self.assertRaises(RpcError):
                android_unlock.parse_keyguard(missing)

    def test_only_system_numeric_credential_pad_is_accepted(self):
        def node(name, attributes=""):
            return (f'<node package="com.android.systemui" enabled="true" '
                    f'resource-id="com.android.systemui:id/{name}" {attributes}/>')
        dump = ("<hierarchy>" + node("pinEntry", 'password="true" text=""') +
                "".join(node("key" + str(i)) for i in range(10)) + "</hierarchy>")
        self.assertTrue(android_unlock.system_pin_pad(dump, empty=True))
        self.assertFalse(android_unlock.system_pin_pad(dump, filled=True))
        for altered in [dump.replace("com.android.systemui", "unknown"),
                        dump.replace("key9", "delete"), dump.replace('text=""', 'text="*"')]:
            self.assertFalse(android_unlock.system_pin_pad(altered, empty=True))

    def test_replaced_device_or_lost_prompt_stops_before_next_digit(self):
        device = AndroidDevice("adb", "serial")
        device.driver, device._check_input, device._pause = Mock(), Mock(), Mock()
        params = {"identity": "original", "pin": "0123"}
        with patch.object(android_unlock, "identity", return_value="other"):
            self.assertEqual(device._submit_unlock_pin(params, "gui")["status"], "needs_user_unlock")
        device.driver.key.assert_not_called()
        with (patch.object(android_unlock, "identity", return_value="original"),
              patch.object(android_unlock, "ready_for_pin", return_value=True),
              patch.object(android_unlock, "system_pin_pad_present", side_effect=[True, False])):
            self.assertEqual(device._submit_unlock_pin(params, "gui")["status"], "unlock_unconfirmed")
        self.assertEqual([c.args for c in device.driver.key.call_args_list], [(0, 7), (1, 7)])
