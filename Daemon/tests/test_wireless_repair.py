import asyncio
import plistlib
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock, patch

from pymobiledevice3.remote.tunnel_service import (
    PairingDataComponentTLV8,
    PairingDataComponentTLVBuf,
    PairingDataComponentType,
    RemotePairingTunnelService,
)

from devicehubd import protocol, transports
from devicehubd.protocol import RpcError
from devicehubd.supervisor import DeviceRecord, Supervisor, WorkerHandle
from devicehubd.transports import (
    WIRELESS_REJECTED,
    PairingRejected,
    _CheckedRemotePairing,
    _remote_pairing_service,
    forget_wireless_pairing,
    mark_wireless_rejected,
    pair_wireless,
    wireless_rejected,
)


def pairing_error(code: bytes) -> bytes:
    return PairingDataComponentTLVBuf.build([
        PairingDataComponentTLV8(PairingDataComponentType.STATE, b"\x02"),
        PairingDataComponentTLV8(PairingDataComponentType.ERROR, code),
    ])


class RecordDirectory:
    """Keeps every test away from the real ~/.pymobiledevice3."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "remote_udid.plist"
        records = patch("devicehubd.transports._remote_record_path", return_value=self.path)
        records.start()
        self.addCleanup(records.stop)


class FakeLockdownPairing:
    """The RemotePairing lockdown service as far as `pair_wireless` drives it."""

    def __init__(self, path: Path, accepted: bool, stale_identifier: str = "") -> None:
        self.identifier = "OWN-HOST"
        self.pair_record_path = path
        self.accepted = accepted
        self.stale_identifier = stale_identifier
        self.paired_as = None
        self._attempt_pair_verify = AsyncMock()
        self.close = AsyncMock()

    async def _validate_pairing(self) -> bool:
        # Upstream adopts the stored record's identifier before the device answers.
        if self.stale_identifier:
            self.identifier = self.stale_identifier
        return self.accepted

    async def _pair(self) -> None:
        self.paired_as = self.identifier
        self.pair_record_path.write_bytes(plistlib.dumps({"private_key": b"new", "peer_alt_irk": b"irk"}))


class PairWirelessTests(RecordDirectory, unittest.IsolatedAsyncioTestCase):
    async def run_pairing(self, service: FakeLockdownPairing) -> bool:
        with patch("devicehubd.transports.RemotePairingLockdownService.create", new=AsyncMock(return_value=service)):
            return await pair_wireless(object())

    async def test_accepted_record_is_kept(self):
        self.path.write_bytes(plistlib.dumps({"private_key": b"old"}))
        service = FakeLockdownPairing(self.path, accepted=True)
        self.assertFalse(await self.run_pairing(service))
        self.assertIsNone(service.paired_as)
        self.assertEqual(plistlib.loads(self.path.read_bytes()), {"private_key": b"old"})
        service.close.assert_awaited_once()

    async def test_refused_record_is_replaced_under_this_macs_identifier(self):
        service = FakeLockdownPairing(self.path, accepted=False, stale_identifier="DEVICE-INITIATED")
        self.assertTrue(await self.run_pairing(service))
        self.assertEqual(service.paired_as, "OWN-HOST")
        record = plistlib.loads(self.path.read_bytes())
        self.assertEqual(record["host_identifier"], "OWN-HOST")
        self.assertEqual(record["private_key"], b"new")
        self.assertEqual(record["peer_alt_irk"], b"irk")
        service.close.assert_awaited_once()

    async def test_new_pairing_clears_a_wifi_refusal(self):
        self.path.write_bytes(plistlib.dumps({"private_key": b"old"}))
        mark_wireless_rejected("udid")
        self.assertTrue(await self.run_pairing(FakeLockdownPairing(self.path, accepted=False)))
        self.assertFalse(wireless_rejected("udid"))

    async def test_failed_pairing_closes_the_channel(self):
        service = FakeLockdownPairing(self.path, accepted=False)
        service._pair = AsyncMock(side_effect=ConnectionError("device locked"))
        with self.assertRaises(ConnectionError):
            await self.run_pairing(service)
        self.assertFalse(self.path.exists())
        service.close.assert_awaited_once()


class RejectionMarkerTests(RecordDirectory, unittest.TestCase):
    def test_marker_keeps_the_record_and_survives_until_forgotten(self):
        self.path.write_bytes(plistlib.dumps({"private_key": b"key", "peer_alt_irk": b"irk"}))
        self.assertFalse(wireless_rejected("udid"))
        mark_wireless_rejected("udid")
        self.assertTrue(wireless_rejected("udid"))
        record = plistlib.loads(self.path.read_bytes())
        self.assertEqual((record["private_key"], record["peer_alt_irk"]), (b"key", b"irk"))
        forget_wireless_pairing("udid")
        self.assertFalse(self.path.exists())
        self.assertFalse(wireless_rejected("udid"))

    def test_marking_without_a_record_creates_nothing(self):
        mark_wireless_rejected("udid")
        self.assertFalse(self.path.exists())


class VerifyAnswerTests(unittest.IsolatedAsyncioTestCase):
    async def validate(self, code: bytes) -> bool:
        service = _CheckedRemotePairing("udid", "192.0.2.1", 49152)
        service._last_pairing_data = pairing_error(code)
        with patch.object(RemotePairingTunnelService, "_validate_pairing", new=AsyncMock(return_value=False)):
            return await service._validate_pairing()

    async def test_authentication_error_is_a_refusal(self):
        with self.assertRaises(PairingRejected):
            await self.validate(b"\x02")

    async def test_busy_device_is_not_a_refusal(self):
        self.assertFalse(await self.validate(b"\x07"))

    async def test_verified_record_passes(self):
        service = _CheckedRemotePairing("udid", "192.0.2.1", 49152)
        with patch.object(RemotePairingTunnelService, "_validate_pairing", new=AsyncMock(return_value=True)):
            self.assertTrue(await service._validate_pairing())


class RefusedOverWifiTests(unittest.IsolatedAsyncioTestCase):
    async def test_refusal_stops_at_the_first_address_and_marks_the_record(self):
        connect = AsyncMock(side_effect=PairingRejected())
        with patch.dict("os.environ", {transports.ENDPOINTS_ENV: '[["192.0.2.1", 49152], ["192.0.2.2", 49152]]'}), \
                patch("devicehubd.transports.wireless_identities", return_value={"udid": b"irk"}), \
                patch("devicehubd.transports._open_remote_pairing", connect), \
                patch("devicehubd.transports.mark_wireless_rejected") as mark, \
                patch("devicehubd.transports.system_bonjour.iter_browse") as browse:
            with self.assertRaises(RpcError) as raised:
                await _remote_pairing_service("udid")
        self.assertEqual(raised.exception.code, WIRELESS_REJECTED)
        connect.assert_awaited_once()
        mark.assert_called_once_with("udid")
        browse.assert_not_called()


class EnsureWirelessTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        with patch("devicehubd.supervisor._load_cache", return_value={}):
            self.supervisor = Supervisor()
        self.forget = patch("devicehubd.supervisor.forget_wireless_pairing").start()
        self.rejected = patch("devicehubd.supervisor.wireless_rejected", return_value=False).start()
        self.addCleanup(patch.stopall)

    async def test_existing_record_is_checked_once_per_cable_attachment(self):
        pairing = AsyncMock(return_value=False)
        with patch("devicehubd.supervisor.pair_wireless", new=pairing), \
                patch("devicehubd.supervisor.has_wireless_pairing", return_value=True):
            record = DeviceRecord("udid", "usb")
            await self.supervisor._ensure_wireless(record, SimpleNamespace())
            await self.supervisor._ensure_wireless(record, SimpleNamespace())
            self.assertEqual(pairing.await_count, 1)
            self.assertTrue(record.wireless)
            # A replugged device gets a fresh record and is checked again.
            await self.supervisor._ensure_wireless(DeviceRecord("udid", "usb"), SimpleNamespace())
        self.assertEqual(pairing.await_count, 2)
        self.forget.assert_not_called()

    async def test_record_refused_over_wifi_is_replaced_even_if_usb_still_verifies_it(self):
        self.rejected.side_effect = [True, False]
        pairing = AsyncMock(return_value=True)
        record = DeviceRecord("udid", "usb")
        with patch("devicehubd.supervisor.pair_wireless", new=pairing), \
                patch("devicehubd.supervisor.has_wireless_pairing", return_value=True), \
                self.assertLogs("devicehubd", level="INFO") as logs:
            await self.supervisor._ensure_wireless(record, SimpleNamespace())
        self.forget.assert_called_once_with("udid")
        pairing.assert_awaited_once()
        self.assertTrue(record.wireless)
        self.assertIn("wireless.repaired udid=udid reason=rejectedOverWifi", "\n".join(logs.output))

    async def test_failure_reports_the_record_on_disk_and_waits_for_a_replug(self):
        pairing = AsyncMock(side_effect=ConnectionError("device locked"))
        record = DeviceRecord("udid", "usb")
        with patch("devicehubd.supervisor.pair_wireless", new=pairing), \
                patch("devicehubd.supervisor.has_wireless_pairing", return_value=False), \
                self.assertLogs("devicehubd", level="WARNING") as logs:
            await self.supervisor._ensure_wireless(record, SimpleNamespace())
            await self.supervisor._ensure_wireless(record, SimpleNamespace())
        self.assertEqual(pairing.await_count, 1)
        self.assertFalse(record.wireless)
        self.assertIn("wireless.repair.failed udid=udid reason=missing", "\n".join(logs.output))


class ExpiredWifiStateTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        with patch("devicehubd.supervisor._load_cache", return_value={}):
            self.supervisor = Supervisor()
        self.supervisor.broadcast = AsyncMock()

    async def fail_worker(self, record: DeviceRecord, code: str) -> None:
        failure = protocol.encode({"event": "failed", "error": {"code": code, "message": "refused"}})
        process = MagicMock(returncode=None, stdout=SimpleNamespace(readline=AsyncMock(side_effect=[failure, b""])))
        process.wait = AsyncMock(return_value=1)
        worker = WorkerHandle(process, asyncio.get_running_loop().create_future())
        self.supervisor.records[record.udid] = record
        self.supervisor.workers[record.udid] = worker
        await self.supervisor._read_worker(record, worker)
        with self.assertRaises(RpcError):
            worker.ready.result()

    async def test_refused_wifi_session_leaves_the_device_waiting_for_a_new_pairing(self):
        record = DeviceRecord("udid", "network", paired=True, developer_mode=True, developer_image=True, wireless=True)
        await self.fail_worker(record, WIRELESS_REJECTED)
        self.assertEqual(record.to_json()["state"], "wirelessPairingExpired")
        self.assertFalse(record.wireless)
        self.assertEqual(record.error, "refused")

    async def test_other_failures_keep_the_device_ready(self):
        record = DeviceRecord("udid", "network", paired=True, developer_mode=True, developer_image=True, wireless=True)
        await self.fail_worker(record, "tunnelFailed")
        self.assertEqual(record.state, "ready")

    async def test_network_probe_reads_the_shared_marker(self):
        record = DeviceRecord("udid", "network")
        with patch("devicehubd.supervisor.wireless_rejected", return_value=True):
            self.supervisor._probe_network(record)
        self.assertEqual(record.state, "wirelessPairingExpired")
        # Pairing again, from either app, rewrites the record without the marker.
        with patch("devicehubd.supervisor.wireless_rejected", return_value=False):
            self.supervisor._probe_network(record)
        self.assertEqual(record.state, "ready")


class SystemWifiTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        with patch("devicehubd.supervisor._load_cache", return_value={}):
            self.supervisor = Supervisor()
        self.supervisor.broadcast = AsyncMock()

    async def test_enabling_over_usb_sets_the_lockdown_value(self):
        self.supervisor.records["udid"] = record = DeviceRecord("udid", "usb", system_wifi=False)
        lockdown = SimpleNamespace(set_enable_wifi_connections=AsyncMock(), close=AsyncMock())
        discovery = SimpleNamespace(lockdown=AsyncMock(return_value=lockdown))
        with patch("devicehubd.supervisor.discovery_for", return_value=discovery):
            await self.supervisor.set_system_wifi("udid", True)
        lockdown.set_enable_wifi_connections.assert_awaited_once_with(True)
        lockdown.close.assert_awaited_once()
        self.assertTrue(record.system_wifi)
        self.assertTrue(record.to_json()["systemWifi"])
        self.supervisor.broadcast.assert_awaited_once()

    async def test_needs_the_cable_and_a_boolean(self):
        self.supervisor.records["udid"] = DeviceRecord("udid", "network")
        with self.assertRaises(RpcError) as raised:
            await self.supervisor.set_system_wifi("udid", True)
        self.assertEqual(raised.exception.code, "needsUsb")
        with self.assertRaises(RpcError) as raised:
            await self.supervisor.set_system_wifi("udid", "yes")
        self.assertEqual(raised.exception.code, "invalidParams")


if __name__ == "__main__":
    unittest.main()
