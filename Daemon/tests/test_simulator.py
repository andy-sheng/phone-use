import json
import unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock, patch

from devicehubd.protocol import RpcError
from devicehubd.simulator import SimulatorAttachment, SimulatorDiscovery, parse_devices, product_type
from devicehubd.supervisor import SIMULATOR_DISCOVERY_FAILURE_LIMIT, Supervisor

LISTING = json.dumps({"devices": {
    "com.apple.CoreSimulator.SimRuntime.iOS-27-1": [
        {"udid": "AAAA", "name": "iPhone 17 Pro", "state": "Booted", "isAvailable": True,
         "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"},
        {"udid": "BBBB", "name": "Shut down", "state": "Shutdown", "isAvailable": True},
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
    def test_only_booted_available_ios_simulators_are_listed(self):
        devices = {device.identifier: device for device in parse_devices(LISTING)}
        self.assertEqual(set(devices), {"AAAA", "CCCC"})
        phone = devices["AAAA"]
        self.assertEqual((phone.udid, phone.name, phone.product_type, phone.product_version),
                         ("simulator:AAAA", "iPhone 17 Pro", "iPhone 17 Pro", "27.1"))
        self.assertEqual(devices["CCCC"].product_type, "iPad Air 11 inch M3")
        self.assertEqual(devices["CCCC"].product_version, "18.6")

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
        command.assert_awaited_once_with("/usr/bin/xcrun", "simctl", "list", "devices", "booted", "-j")

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

    async def test_shutdown_detaches_and_transient_failures_are_tolerated(self):
        await self.poll()
        self.supervisor.simulators.attached.side_effect = ConnectionError("CoreSimulator restarting")
        for _ in range(SIMULATOR_DISCOVERY_FAILURE_LIMIT - 1):
            await self.poll()
        self.assertEqual(self.supervisor.records["simulator:AAAA"].state, "ready")
        self.supervisor.simulators.attached.side_effect = None
        self.supervisor.simulators.attached.return_value = []
        await self.poll()
        self.assertEqual(self.supervisor.records["simulator:AAAA"].state, "disconnected")

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
