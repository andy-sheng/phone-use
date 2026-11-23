import unittest
from unittest.mock import Mock, patch

from devicehubd import android_unlock
from devicehubd.android_worker import AndroidDevice
from devicehubd.protocol import RpcError


class UnlockTests(unittest.TestCase):
    def test_identity_normalizes_unpadded_android_ids(self):
        for raw in ("123456789ABCDEF", "0123456789abcdef"):
            with patch.object(android_unlock, "shell", return_value=raw):
                self.assertEqual(android_unlock.identity("adb", "serial"), "0123456789abcdef")
        for raw in ("null", "", "123456789abcdef01"):
            with patch.object(android_unlock, "shell", return_value=raw), self.assertRaises(RpcError):
                android_unlock.identity("adb", "serial")

    def test_android_keyguard_state_is_explicit(self):
        prefix = "DisplayPolicy\n  KeyguardServiceDelegate\n    showing="
        self.assertTrue(android_unlock.parse_keyguard(prefix + "true\n"))
        self.assertFalse(android_unlock.parse_keyguard(prefix + "false\n"))
        for missing in ["", "showing=false", prefix + "unknown\n"]:
            with self.assertRaises(RpcError):
                android_unlock.parse_keyguard(missing)

    def keypad(self, text=""):
        keys = "".join(f'<node package="com.android.systemui" enabled="true" resource-id="com.android.systemui:id/key{i}" '
                       f'content-desc="{9 - i}" bounds="[{i * 8},0][{i * 8 + 8},8]"/>' for i in range(10))
        return (f'<hierarchy><node package="com.android.systemui" enabled="true" resource-id="com.android.systemui:id/pinEntry" '
                f'password="true" text="{text}"/>{keys}</hierarchy>')

    def test_only_complete_system_keypad_with_distinct_positions_is_accepted(self):
        dump = self.keypad()
        self.assertEqual(android_unlock.pin_keys(dump)["9"], (4, 4))
        self.assertIsNone(android_unlock.pin_keys(dump, filled=True))
        self.assertIsNotNone(android_unlock.pin_keys(self.keypad("*"), filled=True))
        for altered in [dump.replace("com.android.systemui", "unknown"), dump.replace("key9", "delete"),
                        dump.replace('text=""', 'text="*"'), dump.replace('[0,0][8,8]', '[8,0][16,8]'),
                        dump.replace('content-desc="1"', 'content-desc="0"'), dump.replace('[0,0][8,8]', '')]:
            self.assertIsNone(android_unlock.pin_keys(altered))

    def submit(self, locked, *, identity="original", filled=False, prompt=True):
        device = AndroidDevice("adb", "serial")
        device.width = device.height = 100
        device.driver, device._check_input, device._check_geometry, device._pause = Mock(), Mock(), Mock(), Mock()
        def read_keys(*args, **kwargs):
            if kwargs.get("filled"):
                return android_unlock.pin_keys(self.keypad("*"), filled=True) if filled else None
            return android_unlock.pin_keys(self.keypad())
        with (patch.object(android_unlock, "identity", return_value=identity),
              patch.object(android_unlock, "pin_prompt_visible", side_effect=None if isinstance(prompt, bool) else prompt, return_value=prompt),
              patch.object(android_unlock, "locked", side_effect=locked),
              patch.object(android_unlock, "read_pin_keys", side_effect=read_keys) as reads):
            status = device.command({"action": "submitUnlockPIN", "identity": "original", "pin": "0990"})["status"]
        return status, device.driver, reads

    def test_one_layout_drives_repeated_digits_using_displayed_positions(self):
        status, driver, reads = self.submit([True] * 4 + [False])
        self.assertEqual(status, "unlocked")
        reads.assert_called_once_with("adb", "serial")
        self.assertEqual([call.args[:3] for call in driver.touch.call_args_list],
                         [(phase, x, 4) for x in (76, 4, 4, 76) for phase in (0, 1)])
        driver.key.assert_not_called()

    def test_replaced_device_or_unlock_mid_sequence_stops_before_next_digit(self):
        status, driver, reads = self.submit([], identity="other")
        self.assertEqual(status, "needs_user_unlock")
        driver.touch.assert_not_called()
        reads.assert_not_called()
        status, driver, reads = self.submit([True, False])
        self.assertEqual(status, "unlock_unconfirmed")
        self.assertEqual(driver.touch.call_count, 2)
        reads.assert_called_once()

    def test_prompt_disappearing_while_still_locked_stops_remaining_taps(self):
        status, driver, reads = self.submit([True, True], prompt=[True, True, False])
        self.assertEqual(status, "unlock_unconfirmed")
        self.assertEqual(driver.touch.call_count, 2)
        reads.assert_called_once()

    def test_older_device_checks_the_same_layout_when_systemui_omits_its_flag(self):
        status, driver, reads = self.submit([True, True], prompt=False)
        self.assertEqual(status, "unlock_unconfirmed")
        self.assertEqual(driver.touch.call_count, 2)
        reads.assert_called_with("adb", "serial", filled=True)

    def test_enter_is_only_sent_to_a_verified_filled_system_field(self):
        for filled in [True, False]:
            status, driver, reads = self.submit([True] * (6 if filled else 5) + [False], filled=filled)
            self.assertEqual(status, "unlocked")
            self.assertEqual(reads.call_count, 2)
            reads.assert_called_with("adb", "serial", filled=True)
            self.assertEqual([call.args for call in driver.key.call_args_list], [(0, 66), (1, 66)] if filled else [])

    def test_wake_defers_reading_the_layout_until_after_credential_access(self):
        device = AndroidDevice("adb", "serial")
        device.driver, device._pause = Mock(), Mock()
        with (patch.object(android_unlock, "shell"), patch.object(android_unlock, "locked", return_value=True),
              patch.object(android_unlock, "read_pin_keys", return_value=None) as reads):
            self.assertEqual(device.command({"action": "prepareUnlock", "stage": "wake"})["status"], "needs_saved_pin")
            reads.assert_not_called()
            self.assertEqual(device.command({"action": "prepareUnlock", "stage": "keypad"})["status"], "needs_user_unlock")
            reads.assert_called_once()
