import json
import plistlib
import tempfile
import unittest
from datetime import datetime
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock, patch

from devicehubd.protocol import RpcError
from devicehubd.simulator import SimulatorAttachment, SimulatorDiscovery, parse_devices, product_type
from devicehubd.supervisor import DeviceRecord, SIMULATOR_DISCOVERY_FAILURE_LIMIT, Supervisor

LISTING = json.dumps({"devices": {
    "com.apple.CoreSimulator.SimRuntime.iOS-27-1": [
        {"udid": "AAAA", "name": "iPhone 17 Pro", "state": "Booted", "isAvailable": True,
         "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"},
        {"udid": "BBBB", "name": "Shut down", "state": "Shutdown", "isAvailable": True,
         "lastUsedAt": "2026-11-15T07:44:24Z"},
        {"udid": "UNUSED", "name": "Unused default", "state": "Shutdown", "isAvailable": True},
    ],
    "com.apple.CoreSimulator.SimRuntime.iOS-18-6": [
        {"udid": "CCCC", "name": "iPad Air", "state": "Booted",
         "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Air-11-inch-M3"},
        {"udid": "DDDD", "name": "Unavailable", "state": "Booted", "isAvailable": False},
    ],
    "com.apple.CoreSimulator.SimRuntime.watchOS-27-0": [
        {"udid": "EEEE", "name": "Watch", "state": "Booted"},
    ],
}})


class ParsingTests(unittest.TestCase):
    def test_available_ios_simulators_include_used_shutdown_devices_and_hide_unused_defaults(self):
        devices = {device.identifier: device for device in parse_devices(LISTING)}
        self.assertEqual(set(devices), {"AAAA", "BBBB", "CCCC"})
        self.assertEqual(devices["BBBB"].state, "Shutdown")
        self.assertEqual(devices["AAAA"].state, "Booted")
        phone = devices["AAAA"]
        self.assertEqual((phone.udid, phone.name, phone.product_type, phone.product_version),
                         ("simulator:AAAA", "iPhone 17 Pro", "iPhone 17 Pro", "27.1"))
        self.assertEqual(devices["CCCC"].product_type, "iPad Air 11 inch M3")
        self.assertEqual(devices["CCCC"].product_version, "18.6")

    def test_active_simulators_need_no_usage_history(self):
        for state in ("Booted", "Booting", "Shutting Down"):
            with self.subTest(state=state):
                listing = json.dumps({"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-27-1": [
                    {"udid": "NEW", "state": state, "isAvailable": True},
                ]}})
                self.assertEqual([d.identifier for d in parse_devices(listing)], ["NEW"])

    def test_custom_shutdown_simulator_is_visible_before_first_boot(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runtime = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
            defaults_path = root / "device_set.plist"
            defaults_path.write_bytes(plistlib.dumps({"DefaultDevices": {"version": 1, runtime: {"iPhone": "DEFAULT"}}}))
            rows = [{"udid": udid, "name": "Same model", "state": "Shutdown",
                     "dataPath": str(root / udid / "data")} for udid in ["DEFAULT", "CUSTOM"]]
            listing = json.dumps({"devices": {runtime: rows}})
            self.assertEqual([device.identifier for device in parse_devices(listing)], ["CUSTOM"])
            defaults_path.write_bytes(b"unreadable")
            self.assertEqual(parse_devices(listing), [])

    def test_shutdown_usage_history_falls_back_to_device_plist(self):
        Path(".build").mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=".build") as temporary:
            device_dir = Path(temporary)
            listing = json.dumps({"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-27-1": [
                {"udid": "USED", "state": "Shutdown", "dataPath": str(device_dir / "data")},
            ]}})
            metadata_path = device_dir / "device.plist"
            for key in ("lastUsedAt", "lastBootedAt"):
                for fmt in (plistlib.FMT_XML, plistlib.FMT_BINARY):
                    with self.subTest(key=key, format=fmt):
                        metadata_path.write_bytes(plistlib.dumps({key: datetime(2026, 11, 15)}, fmt=fmt))
                        self.assertEqual([d.identifier for d in parse_devices(listing)], ["USED"])
            for metadata in (b"invalid plist", b"<?xml version='1.0'?><plist><dict>",
                             plistlib.dumps({"name": "Unused"})):
                with self.subTest(metadata=metadata):
                    metadata_path.write_bytes(metadata)
                    self.assertEqual(parse_devices(listing), [])
            metadata_path.unlink()
            self.assertEqual(parse_devices(listing), [])

    def test_shutdown_with_last_booted_timestamp_is_visible(self):
        listing = json.dumps({"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-27-1": [
            {"udid": "USED", "state": "Shutdown", "lastBootedAt": "2026-11-15T07:44:24Z"},
        ]}})
        self.assertEqual([d.identifier for d in parse_devices(listing)], ["USED"])

    def test_device_type_names(self):
        self.assertEqual(product_type("com.apple.CoreSimulator.SimDeviceType.iPhone-SE--2nd-generation-"),
                         "iPhone SE 2nd generation")
        self.assertIsNone(product_type(None))
        self.assertIsNone(product_type("unexpected"))


class DiscoveryTests(unittest.IsolatedAsyncioTestCase):
    async def test_listing_is_reused_between_polls_and_runs_without_shell(self):
        discovery = SimulatorDiscovery(interval=60)
        with patch("devicehubd.simulator.find_xcrun", return_value="/usr/bin/xcrun"), \
                patch.object(SimulatorDiscovery, "command", new=AsyncMock(return_value=LISTING)) as command:
            first = await discovery.attached()
            second = await discovery.attached()
        self.assertEqual(first, second)
        command.assert_awaited_once_with("/usr/bin/xcrun", "simctl", "list", "devices", "available", "-j")

    async def test_missing_xcode_lists_nothing(self):
        with patch("devicehubd.simulator.find_xcrun", return_value=None):
            self.assertEqual(await SimulatorDiscovery().attached(), [])


class SupervisorTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        with patch("devicehubd.supervisor._load_cache", return_value={}):
            self.supervisor = Supervisor()
        self.supervisor.broadcast = AsyncMock()
        self.supervisor._schedule_probe = MagicMock()
        self.supervisor.android.attached = AsyncMock(return_value=[])
        self.simulator = SimulatorAttachment("AAAA", "iPhone 17 Pro", "iPhone 17 Pro", "27.1")
        self.supervisor.simulators.attached = AsyncMock(return_value=[self.simulator])

    async def poll(self):
        with patch("devicehubd.supervisor.DISCOVERIES", []):
            await self.supervisor.poll_devices()

    async def test_booted_simulator_is_ready_without_probing(self):
        await self.poll()
        record = self.supervisor.records["simulator:AAAA"]
        published = record.to_json()
        self.assertEqual((published["platform"], published["connection"], published["state"]),
                         ("ios", "simulator", "ready"))
        self.assertEqual((published["name"], published["productVersion"]), ("iPhone 17 Pro", "27.1"))
        self.supervisor._schedule_probe.assert_not_called()

    async def test_deleted_simulator_is_removed_and_transient_failures_are_tolerated(self):
        await self.poll()
        self.supervisor.simulators.attached.side_effect = ConnectionError("CoreSimulator restarting")
        for _ in range(SIMULATOR_DISCOVERY_FAILURE_LIMIT - 1):
            await self.poll()
        self.assertEqual(self.supervisor.records["simulator:AAAA"].state, "ready")
        self.supervisor.simulators.attached.side_effect = None
        self.supervisor.simulators.attached.return_value = []
        await self.poll()
        self.assertNotIn("simulator:AAAA", self.supervisor.records)
        self.assertEqual(self.supervisor.device_list(), [])
        self.supervisor.broadcast.reset_mock()
        await self.poll()
        self.supervisor.broadcast.assert_not_awaited()

    async def test_prolonged_discovery_failure_removes_simulator_until_recovery(self):
        await self.poll()
        self.supervisor.simulators.attached.side_effect = ConnectionError("CoreSimulator restarting")
        for _ in range(SIMULATOR_DISCOVERY_FAILURE_LIMIT):
            await self.poll()
        self.assertEqual(self.supervisor.device_list(), [])
        self.supervisor.simulators.attached.side_effect = None
        await self.poll()
        self.assertEqual(self.supervisor.records["simulator:AAAA"].state, "ready")

    async def test_missing_physical_device_stays_disconnected_while_simulator_is_removed(self):
        self.supervisor.records["phone"] = DeviceRecord("phone", "usb", name="Physical phone")
        await self.poll()
        self.supervisor.simulators.attached.return_value = []
        await self.poll()
        self.assertEqual([d["udid"] for d in self.supervisor.device_list()], ["phone"])
        self.assertEqual(self.supervisor.records["phone"].state, "disconnected")

    async def test_previously_used_shutdown_simulator_cannot_open_until_booted(self):
        self.supervisor.simulators.attached.return_value = [
            SimulatorAttachment("AAAA", "iPhone 17 Pro", "iPhone 17 Pro", "27.1", "Shutdown")]
        await self.poll()
        record = self.supervisor.records["simulator:AAAA"]
        self.assertEqual(record.state, "disconnected")
        self.assertEqual(record.to_json()["simulatorState"], "Shutdown")
        with self.assertRaises(RpcError):
            await self.supervisor.open_device(record.udid)
        self.supervisor.broadcast.reset_mock()
        await self.poll()
        self.supervisor.broadcast.assert_not_awaited()
        self.supervisor.simulators.attached.return_value = [self.simulator]
        await self.poll()
        self.assertEqual(record.state, "ready")
        self.assertEqual(record.to_json()["simulatorState"], "Booted")
        self.assertEqual(self.supervisor.workers, {})

    async def test_shutdown_after_boot_preserves_metadata_and_closes_session(self):
        await self.poll()
        self.supervisor.simulators.attached.return_value = [
            SimulatorAttachment("AAAA", "iPhone 17 Pro", "iPhone 17 Pro", "27.1", "Shutdown")]
        await self.poll()
        record = self.supervisor.records["simulator:AAAA"]
        self.assertEqual(record.state, "disconnected")
        self.assertEqual(record.to_json()["simulatorState"], "Shutdown")
        self.assertEqual(record.name, "iPhone 17 Pro")
        self.assertEqual(record.session, "closed")

    async def test_open_starts_no_worker_and_device_services_are_rejected(self):
        await self.poll()
        self.supervisor._spawn_worker = AsyncMock()
        result = await self.supervisor.open_device("simulator:AAAA")
        self.assertEqual(result, {"udid": "simulator:AAAA", "platform": "ios",
                                  "productVersion": "27.1", "services": []})
        self.supervisor._spawn_worker.assert_not_awaited()
        for method in ("pair", "revealDeveloperMode", "mountDeveloperImage", "openService",
                       "startMirror", "androidCommand", "startAndroidVideo"):
            with self.subTest(method=method), self.assertRaises(RpcError):
                await self.supervisor.dispatch(method, {"udid": "simulator:AAAA"}, SimpleNamespace())
        self.assertEqual(self.supervisor.workers, {})


if __name__ == "__main__":
    unittest.main()
