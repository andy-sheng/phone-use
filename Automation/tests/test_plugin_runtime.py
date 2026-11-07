"""Exercise plugin dispatch and the actual Maa runner without a physical device."""

import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
import uuid
from pathlib import Path
from types import SimpleNamespace

from devicehub_runtime.plugins import discover
from devicehub_runtime.runner import DeviceLease, execute, preflight
from devicehub_runtime.tasks import import_task, refresh_library, write_manifest
from test_controller import FakeBridge

ROOT = Path(__file__).resolve().parents[2]


class PluginRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="devicehub-plugin-run-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        package = self.root / "fixture"
        python = package / "python"
        python.mkdir(parents=True)
        module = "runtime_fixture_" + uuid.uuid4().hex
        (python / f"{module}.py").write_text('''from devicehub_runtime.sdk import PreparedTask
class Plugin:
    def inspect_document(self, document, **kwargs):
        return {"task_id": "imported", "title": kwargs["fallback_title"],
                "issues": [] if document.get("accepted") else ["Fixture rejected document"]}
    def prepare(self, context, task_id, document, config):
        return PreparedTask("Done", pipeline={"Done": {"action": "DoNothing"}})
def create_plugin():
    return Plugin()
''')
        (package / "plugin.json").write_text(json.dumps({
            "schema": "devicehub.plugin.v1", "api_version": 1,
            "id": "runtime-fixture", "name": "Runtime fixture", "version": "1.0.0",
            "entrypoint": module + ":create_plugin", "tasks": [{"id": "run"}],
            "task_types": [{"id": "imported"}],
            "imports": [{"id": "file", "kind": "file", "detect": {"all": ["accepted"]}}],
        }))
        self.addCleanup(sys.modules.pop, module, None)
        self.packages, errors = discover([package])
        self.assertFalse(errors)

    def args(self, **overrides):
        output = self.root / "run"
        output.mkdir(exist_ok=True)
        return SimpleNamespace(command="run", plugin="runtime-fixture", task=None, task_file=None,
                               config="{}", device="fixture", bridge=Path("unused"),
                               assets=ROOT / ".build/maa-core", output=output, watch_stdin=False,
                               **overrides)

    def test_legacy_migration_keeps_title_document_and_plugin_settings(self):
        document = {"accepted": True}
        task = {"schema": "devicehub.task.v1", "title": "User-selected filename", "subtitle": "Flow",
                "description": "", "source": "original.json", "author": "",
                "issues": [], "document": document}
        path = self.root / "old.json"
        write_manifest(path, task)
        self.assertFalse(refresh_library(self.root, self.packages)["errors"])
        migrated = json.loads(path.read_text())
        self.assertEqual(migrated["title"], task["title"])
        self.assertEqual(migrated["document"], document)
        self.assertEqual(migrated["plugin_id"], "runtime-fixture")
        self.assertEqual(migrated["schema"], "devicehub.task.v2")
        self.assertIn("parameters", migrated)
        self.assertIn("phases", migrated)

    def test_preflight_revalidates_payload_and_rejects_forged_compatibility(self):
        source = self.root / "source.json"
        source.write_text(json.dumps({"accepted": False}))
        task = import_task(self.packages, "runtime-fixture", file=source)
        self.assertTrue(task["issues"])
        task["issues"] = []
        saved = self.root / "saved.json"
        write_manifest(saved, task)
        args = self.args()
        args.task_file = saved
        calls = []
        with self.assertRaisesRegex(ValueError, "任务需要适配"):
            execute(args, self.packages, lambda *_a, **_k: None, threading.Event(),
                    bridge_factory=lambda *_: calls.append("connected"))
        self.assertEqual(calls, [])

    def test_unknown_settings_are_rejected_before_device_connection(self):
        args = self.args()
        args.task, args.config = "run", '{"arbitrary": true}'
        with self.assertRaisesRegex(ValueError, "未知任务参数"):
            preflight(args, self.packages)

    def test_physical_device_has_one_owner_until_lease_closes(self):
        first = DeviceLease("fixture", self.root / "locks")
        try:
            with self.assertRaisesRegex(RuntimeError, "已有自动任务"):
                DeviceLease("fixture", self.root / "locks")
            other = DeviceLease("other-fixture", self.root / "locks")
            other.close()
        finally:
            first.close()
        DeviceLease("fixture", self.root / "locks").close()

    def test_generic_runner_executes_pipeline_and_closes_owned_bridge(self):
        source = self.root / "source.json"
        source.write_text(json.dumps({"accepted": True}))
        task = import_task(self.packages, "runtime-fixture", file=source)
        saved = self.root / "saved.json"
        write_manifest(saved, task)
        args = self.args()
        args.task_file = saved
        bridge = FakeBridge()
        bridge.closed = False
        bridge.close = lambda: setattr(bridge, "closed", True)
        events = []
        result = execute(args, self.packages, lambda event, **data: events.append({"event": event, **data}),
                         threading.Event(), bridge_factory=lambda *_: bridge)
        self.assertEqual(result, 0)
        self.assertTrue(bridge.closed)
        self.assertEqual(events[-1]["status"], "completed")
        self.assertFalse(any(method.startswith("touch") for method, _ in bridge.calls))

    def test_stop_watchdog_terminates_an_uncooperative_native_callback(self):
        package = self.root / "stuck"
        python = package / "python"
        python.mkdir(parents=True)
        module = "stuck_" + uuid.uuid4().hex
        (python / f"{module}.py").write_text('''from devicehub_runtime.sdk import PreparedTask
from maa.custom_action import CustomAction
import os, signal, threading, time
class Plugin:
    def prepare(self, context, task_id, document, config):
        class Stuck(CustomAction):
            def run(self, maa_context, argv):
                context.emit("progress", message="entered custom callback")
                os.kill(os.getpid(), signal.SIGINT)
                while True:
                    time.sleep(.1)
        action = Stuck()
        context.resource.register_custom_action("Stuck", action)
        return PreparedTask("Start", pipeline={"Start": {"action": "Custom", "custom_action": "Stuck"}}, references=[action])
def create_plugin():
    return Plugin()
''')
        (package / "plugin.json").write_text(json.dumps({
            "schema": "devicehub.plugin.v1", "api_version": 1, "id": "stuck", "name": "Stuck",
            "version": "1.0.0", "entrypoint": module + ":create_plugin", "tasks": [{"id": "run"}],
        }))
        code = '''import json, sys
from pathlib import Path
from types import SimpleNamespace
from devicehub_runtime.plugins import discover
from devicehub_runtime.runner import run
import devicehub_runtime.controller as controller
from test_controller import FakeBridge
class Bridge(FakeBridge):
    def __init__(self, *_):
        super().__init__()
    def close(self):
        pass
controller.Bridge = Bridge
root, package, output = map(Path, sys.argv[1:])
args = SimpleNamespace(command="run", plugin="stuck", task="run", task_file=None, config="{}", device="fixture",
                       bridge=Path(sys.executable), assets=root/".build/maa-core", output=output, watch_stdin=False)
packages, errors = discover([package])
sys.exit(run(args, packages))
'''
        environment = os.environ | {"PYTHONPATH": os.pathsep.join([str(ROOT / "Automation"), str(ROOT / "Automation/tests")]),
                                    "PYTHONDONTWRITEBYTECODE": "1"}
        result = subprocess.run([sys.executable, "-c", code, str(ROOT), str(package), str(self.root / "stuck-output")],
                                capture_output=True, text=True, timeout=15, env=environment)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("entered custom callback", result.stdout)


if __name__ == "__main__":
    unittest.main()
