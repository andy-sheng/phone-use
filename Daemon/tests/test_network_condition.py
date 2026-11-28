import unittest
from copy import deepcopy
from unittest.mock import AsyncMock, patch

from devicehubd.network_condition import NetworkCondition
from devicehubd.protocol import RpcError


class NetworkConditionTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.conditions = NetworkCondition(None)
        self.network = dict(identifier="SlowNetworkCondition", isActive=False, activeProfile="",
                            profiles=[dict(identifier="3G", name="Average 3G", description="0.78 Mbps")])
        self.thermal = dict(identifier="ThermalCondition", isActive=False, profiles=[])
        self.service = AsyncMock()
        self.service.list.side_effect = lambda: deepcopy([self.thermal, self.network])
        self.service.set.side_effect = lambda profile: self.network.update(isActive=True, activeProfile=profile)
        async def connect(stack):
            def disconnect():
                if self.network.get("activeProfile") == "3G":
                    self.network.update(isActive=False, activeProfile="")
            stack.callback(disconnect)
            return self.service
        mock = patch.object(self.conditions, "_connect", side_effect=connect)
        mock.start()
        self.addCleanup(mock.stop)
        self.addAsyncCleanup(self.conditions.close)

    async def test_start_survives_rpc_and_end_releases_owned_connection(self):
        for _ in range(2):
            result = await self.conditions.command("enableNetworkCondition", {"profile": "3G"})
            self.assertTrue(result["owned"])
        self.service.set.assert_awaited_once_with("3G")
        state = await self.conditions.command("networkCondition", {})
        self.assertEqual(state["activeProfile"], "3G")
        self.assertEqual([p["id"] for p in state["profiles"]], ["3G"])
        self.assertFalse((await self.conditions.command("disableNetworkCondition", {}))["inUse"])
        self.service.clear.assert_not_called()

    async def test_external_conditions_and_unknown_profiles_are_untouched(self):
        self.thermal.update(isActive=True)
        with self.assertRaises(RpcError):
            await self.conditions.command("enableNetworkCondition", {"profile": "3G"})
        state = await self.conditions.command("disableNetworkCondition", {})
        self.assertTrue(state["inUse"])
        self.assertFalse(state["owned"])
        self.thermal.update(isActive=False)
        with self.assertRaises(RpcError):
            await self.conditions.command("enableNetworkCondition", {"profile": "ThermalCritical"})
        self.service.set.assert_not_called()
        self.service.clear.assert_not_called()

    async def test_unsupported_device(self):
        self.service.list.side_effect = lambda: [self.thermal]
        with self.assertRaisesRegex(RpcError, "Network Link"):
            await self.conditions.command("networkCondition", {})
