"""Exercise plugin distribution and the host-facing descriptor contract without devices."""

import contextlib
import io
import json
import stat
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

from devicehub_runtime.plugins import (
    discover, extract_package, install_plugin, pack_plugin, read_manifest,
)
from devicehub_runtime.tasks import refresh_library


class PluginContractTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="devicehub-plugin-contract-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()

    def package(self, directory="package", plugin_id="test-plugin", version="1.0.0", **extra):
        root = self.root / directory
        python = root / "python"
        python.mkdir(parents=True)
        # Catalog and installation must inspect metadata without executing plugin code.
        (python / "contract_plugin.py").write_text("raise RuntimeError('plugin imported during discovery')\n")
        manifest = {
            "schema": "devicehub.plugin.v1", "api_version": 1,
            "id": plugin_id, "name": "Contract fixture", "version": version,
            "entrypoint": "contract_plugin:create_plugin", "python_path": "python",
            "tasks": [], "task_types": [], "imports": [], "resources": [],
        } | extra
        (root / "plugin.json").write_text(json.dumps(manifest))
        return root

    def test_catalog_is_manifest_only_and_isolates_invalid_packages(self):
        self.package("plugins/good", plugin_id="good-plugin")
        self.package("plugins/bad", plugin_id="bad-plugin", imports=[{
            "id": "invalid-import", "title": "Invalid", "kind": "execute",
        }])
        packages, errors = discover([self.root / "plugins"])
        self.assertEqual(set(packages), {"good-plugin"})
        self.assertEqual(len(errors), 1)
        self.assertEqual(packages["good-plugin"].public()["name"], "Contract fixture")

    def test_plugin_diagnostics_do_not_corrupt_import_response(self):
        from devicehub_runtime.__main__ import main

        root = self.package(task_types=[{"id": "custom"}], imports=[{
            "id": "file", "kind": "file", "title": "File",
        }])
        (root / "python/contract_plugin.py").write_text(
            "print('plugin loaded')\n"
            "class Plugin:\n"
            "    def inspect_document(self, document, **kwargs):\n"
            "        print('inspecting task')\n"
            "        return {'task_id': 'custom', 'title': 'Imported', 'issues': []}\n"
            "def create_plugin():\n"
            "    return Plugin()\n"
        )
        self.addCleanup(sys.modules.pop, "contract_plugin", None)
        document = self.root / "input.json"
        document.write_text('{"example": true}')
        output = self.root / "library/imported.json"
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(io.StringIO()):
            status = main([
                "import", "--plugin-root", str(root), "--plugin", "test-plugin",
                "--file", str(document), "--output", str(output),
            ])
        self.assertEqual(status, 0)
        response = json.loads(stdout.getvalue())
        self.assertEqual(response["title"], "Imported")
        self.assertEqual(json.loads(output.read_text())["document"], {"example": True})

    def test_metadata_defaults_are_decodable_by_the_native_ui(self):
        root = self.package(imports=[{"id": "file", "kind": "file"}], tasks=[{
            "id": "run", "parameters": [{
                "key": "mode", "type": "choice", "default": "fast",
                "choices": [{"value": "fast"}],
            }],
        }])
        manifest = read_manifest(root)
        self.assertIsInstance(manifest["imports"][0]["title"], str)
        task = manifest["tasks"][0]
        for key in ("title", "subtitle", "description", "source", "author", "kind", "entry"):
            self.assertIsInstance(task[key], str, key)
        self.assertIsInstance(task["parameters"][0]["title"], str)
        self.assertIsInstance(task["parameters"][0]["choices"][0]["title"], str)

    def test_v1_rejects_ambiguous_import_handlers(self):
        root = self.package(imports=[
            {"id": "one", "title": "First", "kind": "file"},
            {"id": "two", "title": "Second", "kind": "file"},
        ])
        with self.assertRaises(ValueError):
            read_manifest(root)

    def test_newest_version_wins_within_root_and_later_roots_override(self):
        self.package("external/old", version="1.9.0")
        newest = self.package("external/new", version="1.10.0")
        installed = self.package("installed/selected", version="1.2.0")
        packages, errors = discover([self.root / "external"])
        self.assertEqual(errors, [])
        self.assertEqual(packages["test-plugin"].root, newest)
        packages, errors = discover([self.root / "external", self.root / "installed"])
        self.assertEqual(errors, [])
        self.assertEqual(packages["test-plugin"].root, installed)

    def test_default_catalog_uses_only_user_installed_plugins(self):
        from devicehub_runtime.__main__ import main

        self.package("Automation/plugins/source-copy", plugin_id="source-copy")
        self.package(".build/plugins/cached-copy", plugin_id="cached-copy")
        installed = self.root / "installed"
        with patch("devicehub_runtime.plugins.__file__", str(self.root / "Automation/devicehub_runtime/plugins.py")), \
             patch("devicehub_runtime.plugins.INSTALLED_ROOT", installed):
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                self.assertEqual(main(["catalog"]), 0)
            self.assertEqual(json.loads(stdout.getvalue()), {"plugins": [], "errors": []})
            self.package("installed/custom/1.0.0", plugin_id="custom")
            packages, errors = discover()
        self.assertEqual(errors, [])
        self.assertEqual(set(packages), {"custom"})
        self.assertEqual(packages["custom"].location, "installed")

    def test_duplicate_identity_and_version_is_reported(self):
        self.package("plugins/first")
        self.package("plugins/second")
        _, errors = discover([self.root / "plugins"])
        self.assertTrue(errors, "Ambiguous copies of one plugin release must not be silently selected")

    def test_incomplete_installation_is_not_discovered(self):
        self.package("plugins/.install-in-progress/package")
        packages, errors = discover([self.root / "plugins"])
        self.assertEqual(packages, {})
        self.assertEqual(errors, [])

    def test_incompatible_runtime_does_not_hide_compatible_plugin(self):
        self.package("plugins/compatible", plugin_id="compatible")
        self.package("plugins/incompatible", plugin_id="incompatible", requires={"runtime": ">=9999"})
        packages, errors = discover([self.root / "plugins"])
        self.assertEqual(set(packages), {"compatible"})
        self.assertEqual(len(errors), 1)

    def test_missing_maafw_reports_runtime_repair_without_importing_plugins(self):
        from importlib.metadata import PackageNotFoundError

        self.package("plugins/independent", plugin_id="independent")
        self.package("plugins/maa", plugin_id="needs-maa", requires={"maafw": ">=5.6.0,<6.0.0"})
        with patch("devicehub_runtime.plugins.importlib.metadata.version", side_effect=PackageNotFoundError("maafw")):
            packages, errors = discover([self.root / "plugins"])
        self.assertEqual(set(packages), {"independent"})
        self.assertEqual(errors, ["maa：自动化运行环境缺少 MaaFramework，请完成运行环境准备或重新安装 phone-use。"])

    def test_maafw_version_is_checked_without_importing_plugins(self):
        root = self.package(requires={"maafw": ">=5.6.0,<6.0.0"})
        with patch("devicehub_runtime.plugins.importlib.metadata.version", return_value="5.6.0"):
            self.assertEqual(read_manifest(root)["id"], "test-plugin")
        with patch("devicehub_runtime.plugins.importlib.metadata.version", return_value="5.5.0"):
            with self.assertRaisesRegex(ValueError, "插件要求 maafw"):
                read_manifest(root)

    def test_archive_rejects_traversal_and_symlink(self):
        traversal = self.root / "traversal.zip"
        with zipfile.ZipFile(traversal, "w") as archive:
            archive.writestr("../outside.txt", "must not escape")
        output = self.root / "unpacked"
        output.mkdir()
        with self.assertRaises(ValueError):
            extract_package(traversal, output)
        self.assertFalse((self.root / "outside.txt").exists())

        link = self.root / "symlink.zip"
        entry = zipfile.ZipInfo("python/link")
        entry.create_system = 3
        entry.external_attr = (stat.S_IFLNK | 0o777) << 16
        with zipfile.ZipFile(link, "w") as archive:
            archive.writestr(entry, "../../outside.txt")
        with self.assertRaises(ValueError):
            extract_package(link, output)

    def test_archive_rejects_normalized_duplicate_paths(self):
        source = self.root / "duplicate.zip"
        with zipfile.ZipFile(source, "w") as archive:
            archive.writestr("python/entry.py", "original")
            archive.writestr("python/./entry.py", "replacement")
        destination = self.root / "unpacked"
        destination.mkdir()
        with self.assertRaises(ValueError):
            extract_package(source, destination)

    def test_installation_is_idempotent_and_cannot_rewrite_a_release(self):
        source = self.package()
        package_file = self.root / "plugin.devicehub-plugin"
        pack_plugin(source, package_file)
        destination = self.root / "installed"
        first = install_plugin(package_file, destination)
        self.assertEqual(first["plugin_id"], "test-plugin")
        second = install_plugin(package_file, destination)
        self.assertEqual(second["version"], "1.0.0")
        original = (destination / "test-plugin/1.0.0/python/contract_plugin.py").read_text()
        (source / "python/contract_plugin.py").write_text("raise RuntimeError('changed release')\n")
        pack_plugin(source, package_file)
        with self.assertRaises(ValueError):
            install_plugin(package_file, destination)
        self.assertEqual((destination / "test-plugin/1.0.0/python/contract_plugin.py").read_text(), original)
        self.assertFalse(any(destination.glob(".install-*")))

    def test_pinned_assets_must_be_complete_and_match_before_distribution(self):
        source = self.package()
        asset = source / "resources/image/fixture.txt"
        asset.parent.mkdir(parents=True)
        (source / "assets.json").write_text(json.dumps({"files": [{
            "destination": "image/fixture.txt",
            # Git blob object ID for the six bytes b"hello\n".
            "blob_sha": "ce013625030ba8dba906f756967f9e9ca394464a",
        }]}))
        package_file = self.root / "plugin.devicehub-plugin"
        destination = self.root / "installed"
        for state in ("missing", "mismatched"):
            if state == "mismatched":
                asset.write_bytes(b"damaged asset\n")
            with self.subTest(state=state, operation="pack"):
                with self.assertRaisesRegex(ValueError, "插件资源"):
                    pack_plugin(source, package_file)
                self.assertFalse(package_file.exists())
            with self.subTest(state=state, operation="install"):
                with self.assertRaisesRegex(ValueError, "插件资源"):
                    install_plugin(source, destination)
                self.assertFalse((destination / "test-plugin/1.0.0").exists())

        asset.write_bytes(b"hello\n")
        pack_plugin(source, package_file)
        self.assertTrue(package_file.is_file())
        self.assertEqual(install_plugin(source, destination)["plugin_id"], "test-plugin")
        self.assertEqual(install_plugin(package_file, destination)["version"], "1.0.0")
        installed = destination / "test-plugin/1.0.0/resources/image/fixture.txt"
        self.assertEqual(installed.read_bytes(), b"hello\n")

    def test_refresh_preserves_tasks_whose_plugin_is_missing(self):
        library = self.root / "library"
        library.mkdir()
        for schema in ("devicehub.task.v1", "devicehub.task.v2"):
            with self.subTest(schema=schema):
                path = library / "retained-task.json"
                task = {
                    "schema": schema, "title": "Saved task", "author": "Original author",
                    "source": "input.json", "issues": [],
                    "document": {"payload": {"title": "Original document"}},
                }
                if schema.endswith("v2"):
                    task |= {"plugin_id": "missing-plugin", "plugin_version": "1.0.0"}
                path.write_text(json.dumps(task))
                result = refresh_library(library, {})
                retained = json.loads(path.read_text())
                self.assertTrue(result["errors"])
                self.assertTrue(retained["issues"])
                for key, value in task.items():
                    if key != "issues":
                        self.assertEqual(retained[key], value, key)

    def test_scoped_refresh_only_loads_selected_plugin_and_preserves_other_records(self):
        from devicehub_runtime.__main__ import main

        active = self.package("plugins/active", plugin_id="active", entrypoint="active_fixture:create_plugin",
                              task_types=[{"id": "custom"}], imports=[{
                                  "id": "file", "kind": "file", "detect": {"all": ["active_document"]},
                              }])
        (active / "python/active_fixture.py").write_text(
            "class Plugin:\n"
            "    def inspect_document(self, document, **kwargs):\n"
            "        return {'task_id': 'custom', 'title': kwargs['fallback_title'], 'issues': []}\n"
            "def create_plugin():\n"
            "    return Plugin()\n"
        )
        inactive = self.package("plugins/inactive", plugin_id="inactive", entrypoint="inactive_fixture:create_plugin",
                                imports=[{"id": "file", "kind": "file", "detect": {"all": ["other_document"]}}])
        (inactive / "python/inactive_fixture.py").write_text("raise AssertionError('inactive plugin loaded')\n")
        self.addCleanup(sys.modules.pop, "active_fixture", None)
        self.addCleanup(sys.modules.pop, "inactive_fixture", None)
        library = self.root / "library"
        library.mkdir()
        active_task = {"schema": "devicehub.task.v1", "title": "Remembered task",
                       "document": {"active_document": True}, "issues": []}
        selected = library / "active.json"
        selected.write_text(json.dumps(active_task))
        untouched = {
            "inactive.json": json.dumps({"schema": "devicehub.task.v2", "plugin_id": "inactive", "document": {"other_document": True}}),
            "legacy-inactive.json": json.dumps({"schema": "devicehub.task.v1", "document": {"other_document": True}}),
            "missing.json": json.dumps({"schema": "devicehub.task.v2", "plugin_id": "missing", "document": {"x": True}}),
            "unattributed.json": json.dumps({"schema": "devicehub.task.v1", "document": {"unknown": True}}),
            "malformed.json": "{invalid",
        }
        for name, content in untouched.items():
            (library / name).write_text(content)
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(io.StringIO()):
            status = main(["refresh-library", "--plugin-root", str(self.root / "plugins"),
                           "--plugin", "active", "--library", str(library)])
        self.assertEqual(status, 0)
        self.assertEqual(json.loads(stdout.getvalue())["errors"], [])
        migrated = json.loads(selected.read_text())
        self.assertEqual(migrated["plugin_id"], "active")
        self.assertEqual(migrated["title"], active_task["title"])
        self.assertEqual(migrated["document"], active_task["document"])
        self.assertNotIn("inactive_fixture", sys.modules)
        for name, content in untouched.items():
            self.assertEqual((library / name).read_text(), content, name)

    def test_scoped_refresh_rejects_missing_plugin_without_modifying_library(self):
        library = self.root / "library"
        library.mkdir()
        task = library / "saved.json"
        original = '{"schema":"devicehub.task.v2","plugin_id":"missing","document":{"x":true}}'
        task.write_text(original)
        with self.assertRaisesRegex(ValueError, "任务插件未安装或不兼容"):
            refresh_library(library, {}, plugin_id="missing")
        self.assertEqual(task.read_text(), original)

    def test_scoped_refresh_records_selected_legacy_task_errors(self):
        package = self.package(imports=[{"id": "file", "kind": "file", "detect": {"all": ["selected"]}}])
        packages, errors = discover([package])
        self.assertEqual(errors, [])
        library = self.root / "library"
        library.mkdir()
        task = library / "legacy.json"
        original = {"schema": "devicehub.task.v1", "title": "Saved task", "document": {"selected": True}}
        task.write_text(json.dumps(original))
        result = refresh_library(library, packages, plugin_id="test-plugin")
        self.assertEqual(len(result["errors"]), 1)
        retained = json.loads(task.read_text())
        self.assertTrue(retained["issues"])
        for key, value in original.items():
            self.assertEqual(retained[key], value)


if __name__ == "__main__":
    unittest.main()
