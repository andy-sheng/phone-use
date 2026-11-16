import unittest
from unittest.mock import AsyncMock, MagicMock

from devicehubd.protocol import RpcError
from devicehubd.supervisor import WORKER_SETTINGS_METHODS, Supervisor
from devicehubd.worker import accessibility_value, coordinate


class AccessibilityValueTests(unittest.TestCase):
    def test_values_arrive_json_encoded(self):
        self.assertEqual(accessibility_value("REDUCE_MOTION", "true"), ("REDUCE_MOTION", True))
        self.assertEqual(accessibility_value("DYNAMIC_TYPE", "0.5"), ("DYNAMIC_TYPE", 0.5))
        self.assertEqual(accessibility_value("DYNAMIC_TYPE", "1"), ("DYNAMIC_TYPE", 1.0))

    def test_rejects_unknown_settings_and_mismatched_values(self):
        for name, raw in [("VOICE_OVER", "true"), ("REDUCE_MOTION", "1"), ("REDUCE_MOTION", "yes"),
                          ("DYNAMIC_TYPE", "true"), ("DYNAMIC_TYPE", "1.5"), ("DYNAMIC_TYPE", None)]:
            with self.subTest(name=name, raw=raw), self.assertRaises(RpcError):
                accessibility_value(name, raw)


class CoordinateTests(unittest.TestCase):
    def test_parses_string_coordinates(self):
        self.assertEqual(coordinate({"latitude": "37.33", "longitude": "-122.03"}), (37.33, -122.03))

    def test_rejects_missing_or_out_of_range(self):
        for params in [{}, {"latitude": "91", "longitude": "0"}, {"latitude": "x", "longitude": "0"}]:
            with self.subTest(params=params), self.assertRaises(RpcError):
                coordinate(params)


class RoutingTests(unittest.IsolatedAsyncioTestCase):
    async def test_settings_methods_go_to_the_device_worker_without_the_udid(self):
        supervisor = Supervisor.__new__(Supervisor)
        worker = MagicMock()
        worker.call = AsyncMock(return_value={"settings": {}})
        supervisor._ios_record = MagicMock()
        supervisor._worker = AsyncMock(return_value=worker)
        for method in sorted(WORKER_SETTINGS_METHODS):
            with self.subTest(method=method):
                await supervisor.dispatch(method, {"udid": "U", "name": "REDUCE_MOTION", "value": "true"}, MagicMock())
                supervisor._ios_record.assert_called_with("U")
                self.assertEqual(worker.call.call_args.args, (method, {"name": "REDUCE_MOTION", "value": "true"}))


if __name__ == "__main__":
    unittest.main()
