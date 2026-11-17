import io
import json
import os
import queue
import tempfile
import threading
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import Mock, patch

from devicehub_runtime.controller import Bridge
from devicehub_runtime.diagnostics import BridgeTrace


class BridgeDiagnosticsTests(unittest.TestCase):
    def test_timeout_has_request_run_and_child_but_no_payload_or_protocol_output(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {
            "DEVICEHUB_RUN_LOG_DIR": directory, "DEVICEHUB_RUN_ID": "fixture-run"
        }):
            bridge = Bridge.__new__(Bridge)
            bridge.trace = BridgeTrace()
            self.addCleanup(bridge.trace.close)
            bridge.process = Mock(pid=123, stdin=io.StringIO())
            bridge.process.poll.return_value = None
            bridge._responses = Mock()
            bridge._responses.get.side_effect = queue.Empty
            bridge._lock = threading.Lock()
            bridge._serial = 0
            bridge._closed = False
            output = io.StringIO()
            with redirect_stdout(output), self.assertRaisesRegex(TimeoutError, "screenshot timed out"):
                bridge.request("screenshot", password="never-log-this")
            self.assertTrue(bridge._closed)
            self.assertTrue(bridge.process.stdin.closed)
            text = (Path(directory) / "bridge.jsonl").read_text()
            records = [json.loads(line) for line in text.splitlines()]
            self.assertEqual([r["event"] for r in records], ["request.begin", "request.failed"])
            self.assertEqual(records[-1]["run"], "fixture-run")
            self.assertEqual(records[-1]["child_pid"], 123)
            self.assertEqual(records[-1]["request"], 1)
            self.assertEqual(records[-1]["error_type"], "TimeoutError")
            self.assertEqual(records[-1]["timeout_ms"], 30000)
            self.assertNotIn("never-log-this", text)
            self.assertEqual(output.getvalue(), "")
            bridge.trace.close()

    def test_rotation_retains_recent_failure(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"DEVICEHUB_RUN_LOG_DIR": directory}):
            trace = BridgeTrace()
            trace.handler.maxBytes = 300
            for index in range(20):
                trace.record("request.ok", request=index)
            trace.record("request.failed", error_type="TimeoutError")
            trace.close()
            self.assertEqual(len(list(Path(directory).glob("bridge.jsonl*"))), 2)
            self.assertIn("TimeoutError", (Path(directory) / "bridge.jsonl").read_text())

    def test_unwritable_log_does_not_prevent_device_work(self):
        with patch.dict(os.environ, {"DEVICEHUB_RUN_LOG_DIR": "/dev/null/no-directory"}), patch("sys.stderr", io.StringIO()):
            trace = BridgeTrace()
            trace.record("request.begin")
            trace.close()
