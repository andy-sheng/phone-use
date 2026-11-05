import asyncio
import time
import unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock, patch

from pymobiledevice3.bonjour import Address, ServiceInstance
from pymobiledevice3.exceptions import RemotePairingCompletedError

from devicehubd.protocol import RpcError
from devicehubd.supervisor import DeviceRecord, Supervisor
from devicehubd.transports import NETWORK_TTL, NetworkDiscovery
from devicehubd.wireless_pairing import IOSManualPairingService, PairedDevice, WirelessPairing


def advertisement(identifier="nearby", model="iPhone18,1"):
    return ServiceInstance(
        instance="Nearby._remotepairing-manual-pairing._tcp.local.", host="nearby.local", port=12345,
        addresses=[Address("fe80::123", "en0"), Address("192.0.2.1", "en0")],
        properties={"identifier": identifier, "name": "Test iPhone", "model": model},
    )


class WirelessPairingTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.callback = AsyncMock()
        self.pairing = WirelessPairing(self.callback)

    async def asyncTearDown(self):
        await self.pairing.close()

    async def wait_terminal(self):
        async def wait():
            while self.pairing.active:
                await asyncio.sleep(0)
        await asyncio.wait_for(wait(), 1)

    async def test_discovery_finds_unpaired_devices_and_expires_stale_answers(self):
        browsed = asyncio.Event()

        async def browse(*args):
            yield advertisement()
            yield advertisement("television", "AppleTV14,1")
            browsed.set()

        with patch("devicehubd.wireless_pairing.iter_browse_service", browse):
            self.pairing._spawn(self.pairing._browse())
            await asyncio.wait_for(browsed.wait(), 1)
            self.assertEqual(self.pairing.snapshot()["devices"], [{"id": "nearby", "name": "Test iPhone"}])
            with patch("devicehubd.wireless_pairing.time.monotonic", return_value=time.monotonic() + NETWORK_TTL + 1):
                self.assertEqual(self.pairing.snapshot()["devices"], [])
                with self.assertRaises(RpcError) as caught:
                    self.pairing.pair("nearby")
                self.assertEqual(caught.exception.code, "deviceNotFound")
        self.callback.assert_not_awaited()

    async def test_start_and_cancel_close_advertisement_listener_and_discovery(self):
        listener = MagicMock()
        server = MagicMock(sockets=[MagicMock(getsockname=lambda: ("::", 12345))])
        server.wait_closed = AsyncMock()
        advertiser = MagicMock()
        advertiser.__aenter__ = AsyncMock()
        advertiser.__aexit__ = AsyncMock()
        started = asyncio.Event()
        stopped = asyncio.Event()

        async def browse(*args):
            started.set()
            try:
                await asyncio.Future()
                yield advertisement()
            finally:
                stopped.set()

        with patch("devicehubd.wireless_pairing.socket.socket", return_value=listener), \
                patch("devicehubd.wireless_pairing.asyncio.start_server", new=AsyncMock(return_value=server)), \
                patch("devicehubd.wireless_pairing.MDNSResponder", return_value=advertiser), \
                patch("devicehubd.wireless_pairing.iter_browse_service", browse):
            await self.pairing.start()
            await asyncio.wait_for(started.wait(), 1)
            self.assertEqual(self.pairing.state, "waiting")
            await self.pairing.close()
        self.assertTrue(stopped.is_set())
        self.assertEqual(self.pairing.state, "cancelled")
        server.close.assert_called_once()
        server.wait_closed.assert_awaited_once()
        advertiser.__aexit__.assert_awaited_once()
        self.assertFalse(self.pairing._tasks)

    async def test_start_failure_cleans_up_partial_advertisement(self):
        server = MagicMock(sockets=[MagicMock(getsockname=lambda: ("::", 12345))])
        server.wait_closed = AsyncMock()
        advertiser = MagicMock()
        advertiser.__aenter__ = AsyncMock(side_effect=OSError("network denied"))
        advertiser.__aexit__ = AsyncMock()
        with patch("devicehubd.wireless_pairing.socket.socket", return_value=MagicMock()), \
                patch("devicehubd.wireless_pairing.asyncio.start_server", new=AsyncMock(return_value=server)), \
                patch("devicehubd.wireless_pairing.MDNSResponder", return_value=advertiser):
            with self.assertRaises(OSError):
                await self.pairing.start()
        server.close.assert_called_once()
        advertiser.__aexit__.assert_awaited_once()

    async def test_manual_pairing_completed_signal_is_success_and_closes_service(self):
        service = MagicMock(remote_device_model="iPhone18,1")
        service.connect = AsyncMock(side_effect=RemotePairingCompletedError())
        service.close = AsyncMock()
        self.pairing._nearby["nearby"] = (advertisement(), time.monotonic())
        with patch("devicehubd.wireless_pairing.IOSManualPairingService", return_value=service):
            self.pairing.pair("nearby")
            with self.assertRaises(RpcError):
                self.pairing.pair("nearby")
            await self.wait_terminal()
        self.assertEqual(self.pairing.state, "paired")
        self.callback.assert_awaited_once_with(PairedDevice("nearby", "Test iPhone", "iPhone18,1"))
        service.close.assert_awaited_once()

    async def test_transport_address_failure_falls_back_before_consent_only(self):
        first = MagicMock(handshake_info=None)
        first.connect = AsyncMock(side_effect=OSError("unreachable"))
        first.close = AsyncMock()
        second = MagicMock(remote_device_model="iPhone18,1")
        second.connect = AsyncMock(side_effect=RemotePairingCompletedError())
        second.close = AsyncMock()
        with patch("devicehubd.wireless_pairing.IOSManualPairingService", side_effect=[first, second]):
            await self.pairing._pair_manual("nearby", advertisement())
        self.assertEqual(self.pairing.state, "paired")
        first.close.assert_awaited_once()
        second.close.assert_awaited_once()

    async def test_pairing_error_after_handshake_does_not_replay_on_another_address(self):
        service = MagicMock(handshake_info={"peerDeviceInfo": {}})
        service.connect = AsyncMock(side_effect=OSError("closed after consent"))
        service.close = AsyncMock()
        with patch("devicehubd.wireless_pairing.IOSManualPairingService", return_value=service) as factory:
            await self.pairing._pair_manual("nearby", advertisement())
        factory.assert_called_once_with("nearby", "fe80::123%en0", 12345)
        self.assertEqual(self.pairing.state, "failed")
        self.callback.assert_not_awaited()

    async def test_non_ios_manual_pairing_cannot_call_terminal_pin_prompt(self):
        service = IOSManualPairingService("nearby", "192.0.2.1", 12345)
        service.handshake_info = {"peerDeviceInfo": {"model": "AppleTV14,1"}}
        with patch("pymobiledevice3.remote.tunnel_service.RemotePairingManualPairingService._request_pair_consent",
                   new=AsyncMock()) as prompt:
            with self.assertRaises(RpcError):
                await service._request_pair_consent()
        prompt.assert_not_awaited()

    def host(self, *, failure=False, hanging=False):
        host = MagicMock()
        host.close = AsyncMock()

        async def accept(show_pin):
            show_pin("123456")
            if hanging:
                await asyncio.Future()
            if failure:
                raise ValueError("wrong code")
            return SimpleNamespace(udid="test-udid", account_id="account", name="Test iPad", model="iPad14,5")
        host.accept = AsyncMock(side_effect=accept)
        return host

    async def test_device_initiated_pairing_saves_only_after_accept_and_hides_code(self):
        host = self.host()

        async def paired(device):
            host.save_pair_record.assert_called_once()
            self.assertIsNone(self.pairing.pin)
        self.callback.side_effect = paired
        with patch("devicehubd.wireless_pairing.PairableHost", return_value=host):
            self.pairing._accept(MagicMock(), MagicMock())
            await self.wait_terminal()
        self.assertEqual(self.pairing.snapshot()["pairedUDID"], "test-udid")
        self.assertIsNone(self.pairing.snapshot()["pin"])
        host.close.assert_awaited_once()

    async def test_wrong_code_does_not_save_or_add_device(self):
        host = self.host(failure=True)
        with patch("devicehubd.wireless_pairing.PairableHost", return_value=host):
            self.pairing._accept(MagicMock(), MagicMock())
            await self.wait_terminal()
        host.save_pair_record.assert_not_called()
        self.callback.assert_not_awaited()
        self.assertEqual(self.pairing.state, "failed")
        self.assertIsNone(self.pairing.pin)

    async def test_cancel_mid_pairing_clears_pin_and_closes_peer_without_saving(self):
        host = self.host(hanging=True)
        with patch("devicehubd.wireless_pairing.PairableHost", return_value=host):
            self.pairing._accept(MagicMock(), MagicMock())
            await asyncio.sleep(0)
            self.assertEqual(self.pairing.pin, "123456")
            refused = MagicMock()
            self.pairing._accept(MagicMock(), refused)
            refused.close.assert_called_once()
            await self.pairing.close()
        host.close.assert_awaited_once()
        host.save_pair_record.assert_not_called()
        self.assertIsNone(self.pairing.pin)
        self.assertFalse(self.pairing._tasks)

    async def test_session_timeout_cancels_an_incomplete_pairing(self):
        host = self.host(hanging=True)
        with patch("devicehubd.wireless_pairing.PairableHost", return_value=host), \
                patch("devicehubd.wireless_pairing.PAIRING_LIFETIME", 0):
            self.pairing._accept(MagicMock(), MagicMock())
            await asyncio.sleep(0)
            await self.pairing._expire()
        self.assertEqual(self.pairing.state, "failed")
        self.assertIn("timed out", self.pairing.error)
        host.close.assert_awaited_once()
        host.save_pair_record.assert_not_called()


class SupervisorWirelessTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        with patch("devicehubd.supervisor._load_cache", return_value={}):
            self.supervisor = Supervisor()
        self.supervisor.broadcast = AsyncMock()
        self.owner, self.stranger = MagicMock(), MagicMock()
        self.owner.is_closing.return_value = False
        self.stranger.is_closing.return_value = False

    async def test_queued_start_after_client_disconnect_does_not_advertise(self):
        self.owner.is_closing.return_value = True
        with patch("devicehubd.supervisor.WirelessPairing") as pairing:
            with self.assertRaises(RpcError) as caught:
                await self.supervisor.dispatch("startWirelessPairing", {}, self.owner)
        self.assertEqual(caught.exception.code, "disconnected")
        pairing.assert_not_called()

    async def test_session_codes_and_actions_are_private_to_owning_client(self):
        pairing = MagicMock(session_id="session", active=True)
        pairing.start = AsyncMock()
        pairing.close = AsyncMock()
        pairing.snapshot.return_value = {"sessionID": "session", "pin": "123456"}
        params = {"sessionID": "session", "deviceID": "nearby"}
        with patch("devicehubd.supervisor.WirelessPairing", return_value=pairing):
            await self.supervisor.dispatch("startWirelessPairing", {}, self.owner)
            for method in ("wirelessPairingStatus", "pairNearbyDevice"):
                with self.assertRaises(RpcError):
                    await self.supervisor.dispatch(method, params, self.stranger)
            await self.supervisor.dispatch("stopWirelessPairing", params, self.stranger)
            pairing.close.assert_not_awaited()
            with self.assertRaises(RpcError):
                await self.supervisor.dispatch("startWirelessPairing", {}, self.stranger)
            result = await self.supervisor.dispatch("wirelessPairingStatus", params, self.owner)
            self.assertEqual(result["sessionID"], "session")
            await self.supervisor.dispatch("pairNearbyDevice", params, self.owner)
            pairing.pair.assert_called_once_with("nearby")
            await self.supervisor.dispatch("stopWirelessPairing", {"sessionID": "old"}, self.owner)
            pairing.close.assert_not_awaited()
            await self.supervisor.dispatch("stopWirelessPairing", params, self.owner)
            pairing.close.assert_awaited_once()

    async def test_client_disconnect_and_shutdown_stop_pairing(self):
        pairing = MagicMock(session_id="session", active=True)
        pairing.close = AsyncMock()
        self.supervisor._wireless_pairing, self.supervisor._wireless_owner = pairing, self.owner
        reader = SimpleNamespace(readline=AsyncMock(return_value=b""))
        await self.supervisor.serve_client(reader, self.owner)
        pairing.close.assert_awaited_once()
        self.supervisor._wireless_pairing, self.supervisor._wireless_owner = pairing, self.owner
        await self.supervisor.shutdown()
        self.assertEqual(pairing.close.await_count, 2)

    async def test_success_joins_shared_list_and_discovery_without_usb(self):
        network = NetworkDiscovery()
        self.supervisor._cache["test-udid"] = {"name": "Old name", "developer_mode": False}
        with patch("devicehubd.supervisor.DISCOVERIES", [network]), patch("devicehubd.supervisor._save_cache"):
            await self.supervisor._wireless_paired(PairedDevice("test-udid", "Test iPad", "iPad14,5"))
        record = self.supervisor.records["test-udid"]
        self.assertEqual(record.connection, "network")
        self.assertEqual(record.state, "ready")
        self.assertEqual(record.name, "Test iPad")
        self.assertIn("test-udid", network._seen)
        self.assertTrue(record.wireless)
        self.supervisor.broadcast.assert_awaited_once()

    async def test_pairing_preserves_existing_usb_session_and_metadata(self):
        record = DeviceRecord("test-udid", "usb", product_version="27.1", session="open")
        self.supervisor.records["test-udid"] = record
        with patch("devicehubd.supervisor.DISCOVERIES", []), patch("devicehubd.supervisor._save_cache"):
            await self.supervisor._wireless_paired(PairedDevice("test-udid", "Test iPhone", "iPhone18,1"))
        self.assertIs(self.supervisor.records["test-udid"], record)
        self.assertEqual(record.connection, "usb")
        self.assertEqual(record.session, "open")
        self.assertEqual(record.product_version, "27.1")
