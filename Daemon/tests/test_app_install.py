import tempfile
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, patch

from devicehubd.app_install import install_ipa, package_file
from devicehubd.protocol import RpcError
from devicehubd.supervisor import DeviceRecord, Supervisor


class AppInstallTests(unittest.IsolatedAsyncioTestCase):
    def test_requires_absolute_regular_file_for_target_platform(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / "My Game.IPA"
            file.touch()
            self.assertEqual(package_file(str(file), ".ipa"), file)
            for bad in (None, "My Game.IPA", str(file) + "\0", str(file.with_suffix(".ipa.tmp")),
                        str(Path(directory) / "missing.ipa")):
                with self.assertRaises(RpcError):
                    package_file(bad, ".ipa")
            with self.assertRaises(RpcError):
                package_file(str(file), ".apk")

    async def test_android_routes_install_to_exact_serial_and_checks_result(self):
        supervisor = Supervisor()
        device = DeviceRecord("android:emulator-5554", "emulator", platform="android",
                              adb_state="device", adb_serial="emulator-5554")
        supervisor.records[device.udid] = device
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / "My Game.apk"
            file.touch()
            params = {"udid": device.udid, "path": str(file)}
            with patch.object(supervisor.android, "command", new_callable=AsyncMock) as adb:
                adb.return_value = "Performing Streamed Install\nSuccess\n"
                self.assertEqual(await supervisor.dispatch("installApp", params, None), {})
                adb.assert_awaited_once_with("-s", "emulator-5554", "install", "-r", str(file), timeout=600)
                adb.return_value = "Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE]"
                with self.assertRaisesRegex(RpcError, "INSTALL_FAILED_UPDATE_INCOMPATIBLE"):
                    await supervisor.dispatch("installApp", params, None)
                device.adb_state = "offline"
                adb.reset_mock()
                with self.assertRaises(RpcError):
                    await supervisor.dispatch("installApp", params, None)
                adb.assert_not_awaited()

    async def test_ipa_removes_staged_copy_even_if_signature_is_rejected(self):
        afc, installer = AsyncMock(), AsyncMock()
        with (patch("devicehubd.app_install.AfcService") as transfer,
              patch("devicehubd.app_install.InstallationProxyService") as proxy):
            transfer.return_value.__aenter__.return_value = afc
            proxy.return_value.__aenter__.return_value = installer
            installer.send_package.side_effect = RuntimeError("Invalid signature")
            with self.assertRaisesRegex(RuntimeError, "Invalid signature"):
                await install_ipa(object(), Path("/local/My Game.ipa"))
            staged = afc.push.await_args.args[1]
            self.assertTrue(staged.startswith("/PublicStaging/") and staged.endswith(".ipa"))
            afc.push.assert_awaited_once_with("/local/My Game.ipa", staged, progress_bar=False)
            installer.send_package.assert_awaited_once_with("Install", {}, None, staged)
            afc.rm_single.assert_awaited_once_with(staged, force=True)
