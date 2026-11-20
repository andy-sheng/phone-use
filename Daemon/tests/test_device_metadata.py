import asyncio
import unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock, patch

from devicehubd import protocol
from devicehubd.supervisor import DeviceRecord, Supervisor, WorkerHandle
from devicehubd.worker import device_metadata


class WorkerMetadataTests(unittest.TestCase):
    def test_reads_name_from_tunnel_lockdown_and_falls_back_to_handshake(self):
        rsd = SimpleNamespace(
            all_values={"DeviceName": "Test iPhone", "BuildVersion": ""},
            peer_info={"Properties": {"ProductType": "iPhone15,2", "BuildVersion": "23A100"}},
        )
        self.assertEqual(device_metadata(rsd), {
            "deviceName": "Test iPhone", "productType": "iPhone15,2", "buildVersion": "23A100",
        })

    def test_device_without_lockdown_reports_only_what_it_has(self):
        self.assertEqual(device_metadata(SimpleNamespace(all_values={}, peer_info=None)), {})


class SupervisorWorkerReadyTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        with patch("devicehubd.supervisor._load_cache", return_value={}):
            self.supervisor = Supervisor()
        self.supervisor.broadcast = AsyncMock()

    async def ready(self, record: DeviceRecord, message: dict) -> None:
        lines = [protocol.encode({"event": "ready", **message}), b""]
        process = MagicMock(returncode=None, stdout=SimpleNamespace(readline=AsyncMock(side_effect=lines)))
        process.wait = AsyncMock(return_value=0)
        worker = WorkerHandle(process, asyncio.get_running_loop().create_future())
        self.supervisor.records[record.udid] = record
        self.supervisor.workers[record.udid] = worker
        await self.supervisor._read_worker(record, worker)

    async def test_network_only_device_learns_and_caches_its_name_when_the_tunnel_opens(self):
        record = DeviceRecord("test-udid", "network", paired=True, developer_mode=True, developer_image=True)
        self.assertEqual(record.to_json()["name"], "test-udid")
        with patch("devicehubd.supervisor._save_cache") as save:
            await self.ready(record, {"productVersion": "26.1", "deviceName": "Test iPhone",
                                      "productType": "iPhone15,2", "buildVersion": "23B85"})
        self.assertEqual(record.to_json()["name"], "Test iPhone")
        self.assertEqual(record.product_type, "iPhone15,2")
        cached = self.supervisor._cache["test-udid"]
        self.assertEqual((cached["name"], cached["product_version"]), ("Test iPhone", "26.1"))
        save.assert_called_once()

    async def test_ready_without_metadata_keeps_known_name(self):
        record = DeviceRecord("test-udid", "usb", name="Known", product_type="iPhone15,2", paired=True)
        with patch("devicehubd.supervisor._save_cache"):
            await self.ready(record, {"productVersion": "26.1"})
        self.assertEqual(record.name, "Known")
        self.assertEqual(record.product_type, "iPhone15,2")


if __name__ == "__main__":
    unittest.main()
