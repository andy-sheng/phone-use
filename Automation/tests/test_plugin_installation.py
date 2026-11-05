"""Distribution files and HTTP installation use the same non-executing package checks."""

import contextlib
import io
import json
import sys
import tempfile
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from unittest.mock import patch

from devicehub_runtime.__main__ import main, parser
from devicehub_runtime.plugins import (
    PackageRedirectHandler, install_plugin, install_plugin_url, pack_plugin, validate_download_url,
)


class DownloadResponse(io.BytesIO):
    status = 200

    def __init__(self, data, *, length=None, url="https://example.test/release/download"):
        super().__init__(data)
        self.headers = {} if length is None else {"Content-Length": str(length)}
        self.url = url

    def geturl(self):
        return self.url


class PluginInstallationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="devicehub-plugin-install-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.destination = self.root / "installed"
        self.source = self.root / "source"
        (self.source / "python").mkdir(parents=True)
        (self.source / "python/install_fixture.py").write_text("raise AssertionError('plugin executed during install')\n")
        (self.source / "plugin.json").write_text(json.dumps({
            "schema": "devicehub.plugin.v1", "api_version": 1,
            "id": "install-fixture", "name": "Install fixture", "version": "1.0.0",
            "entrypoint": "install_fixture:create_plugin", "python_path": "python",
            "resources": [], "tasks": [], "task_types": [], "imports": [],
        }))
        self.archive = self.root / "install-fixture-1.0.0.dhplugin"
        pack_plugin(self.source, self.archive)

    @contextlib.contextmanager
    def download(self, data=None, **kwargs):
        with patch("devicehub_runtime.plugins.urllib.request.build_opener") as factory:
            response = DownloadResponse(self.archive.read_bytes() if data is None else data, **kwargs)
            factory.return_value.open.return_value = response
            yield factory.return_value.open

    def assert_clean(self):
        self.assertEqual(list(self.destination.glob(".download-*")), [])
        self.assertEqual(list(self.destination.glob(".install-*")), [])

    def test_dhplugin_roundtrip_and_legacy_installers_do_not_execute_code(self):
        for source, name in [(self.archive, "package"), (self.source, "directory")]:
            result = install_plugin(source, self.root / name)
            installed = self.root / name / "install-fixture/1.0.0"
            self.assertEqual(result["plugin_id"], "install-fixture")
            self.assertEqual((installed / "python/install_fixture.py").read_bytes(),
                             (self.source / "python/install_fixture.py").read_bytes())
        legacy = self.root / "legacy.zip"
        pack_plugin(self.source, legacy)
        self.assertEqual(install_plugin(legacy, self.destination)["version"], "1.0.0")
        self.assertNotIn("install_fixture", sys.modules)

    def test_url_cli_installs_extensionless_download_and_cleans_temp_files(self):
        payload = self.archive.read_bytes()
        output = io.StringIO()
        with self.download(length=len(payload)) as request, contextlib.redirect_stdout(output):
            result = main(["install", "--url", "https://example.test/release/download?token=private",
                           "--destination", str(self.destination)])
        self.assertEqual(result, 0)
        self.assertEqual(json.loads(output.getvalue())["plugin_id"], "install-fixture")
        self.assertEqual(request.call_args.kwargs["timeout"], 10)
        self.assertTrue((self.destination / "install-fixture/1.0.0/plugin.json").is_file())
        self.assertNotIn("private", output.getvalue())
        self.assertNotIn("install_fixture", sys.modules)
        self.assert_clean()

    def test_local_and_url_cli_sources_are_mutually_exclusive(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            parser().parse_args(["install", "--package", str(self.archive), "--url", "https://example.test/a"])

    def test_url_validation_rejects_invalid_schemes_credentials_and_ports(self):
        for value in ["file:///etc/passwd", "ftp://example.test/a", "https://name:secret@example.test/a",
                      "https:///a", "https://example.test:99999/a", "https://example.test/a\nHeader:secret",
                      "https://example.test:0/a", "https://example.test\\@another.test/a"]:
            with self.subTest(value=value), self.assertRaises(ValueError) as error:
                install_plugin_url(value, self.destination)
            self.assertNotIn("secret", str(error.exception))
        self.assertEqual(validate_download_url("http://127.0.0.1:8765/plugin.dhplugin#download"),
                         "http://127.0.0.1:8765/plugin.dhplugin")

    def test_redirects_validate_destinations_disallow_downgrade_and_are_bounded(self):
        request = urllib.request.Request("https://example.test/start")
        handler = PackageRedirectHandler(float("inf"))
        for destination in ["file:///tmp/a", "http://example.test/a", "https://name:secret@example.test/a"]:
            with self.subTest(destination=destination), self.assertRaises(ValueError):
                handler.redirect_request(request, None, 302, "Found", {}, destination)
        handler = PackageRedirectHandler(float("inf"))
        for number in range(5):
            result = handler.redirect_request(request, None, 302, "Found", {}, f"https://example.test/{number}")
            self.assertEqual(result.full_url, f"https://example.test/{number}")
        with self.assertRaisesRegex(ValueError, "重定向次数"):
            handler.redirect_request(request, None, 302, "Found", {}, "https://example.test/last")
        with self.assertRaises(TimeoutError):
            PackageRedirectHandler(0).redirect_request(request, None, 302, "Found", {}, "https://example.test/last")

    def test_declared_and_streamed_size_limits_leave_no_install(self):
        for length in [100, None]:
            with self.subTest(length=length), patch("devicehub_runtime.plugins.MAX_PACKAGE_BYTES", 32), self.download(b"x" * 64, length=length):
                with self.assertRaisesRegex(ValueError, "插件包过大"):
                    install_plugin_url("https://example.test/a", self.destination)
            self.assertFalse((self.destination / "install-fixture").exists())
            self.assert_clean()

    def test_truncated_download_and_invalid_zip_leave_no_install(self):
        for data, length, message in [(b"not zip", 100, "下载不完整"), (b"not zip", None, "不是有效")]:
            with self.subTest(message=message), self.download(data, length=length):
                with self.assertRaisesRegex(ValueError, message):
                    install_plugin_url("https://example.test/a", self.destination)
            self.assertFalse((self.destination / "install-fixture").exists())
            self.assert_clean()

    def test_network_errors_and_timeout_do_not_leak_signed_url(self):
        signed = "https://example.test/download?token=private"
        failures = [urllib.error.HTTPError(signed, 403, "Forbidden", {}, None),
                    urllib.error.URLError(signed), TimeoutError()]
        for failure in failures:
            with self.subTest(failure=type(failure).__name__), patch("devicehub_runtime.plugins.urllib.request.build_opener") as factory:
                factory.return_value.open.side_effect = failure
                with self.assertRaises(ValueError) as error:
                    install_plugin_url(signed, self.destination)
                self.assertNotIn("private", str(error.exception))
            self.assert_clean()

    def test_total_deadline_stops_slow_download(self):
        with self.download(), patch("devicehub_runtime.plugins.time.monotonic", side_effect=[0, 121]):
            with self.assertRaisesRegex(ValueError, "超时"):
                install_plugin_url("https://example.test/a", self.destination)
        self.assert_clean()

    def test_conflicting_remote_version_does_not_replace_existing_install(self):
        install_plugin(self.archive, self.destination)
        installed = self.destination / "install-fixture/1.0.0/python/install_fixture.py"
        original = installed.read_bytes()
        (self.source / "python/install_fixture.py").write_text("raise AssertionError('changed')\n")
        pack_plugin(self.source, self.archive)
        with self.download(), self.assertRaisesRegex(ValueError, "内容不同"):
            install_plugin_url("https://example.test/a", self.destination)
        self.assertEqual(installed.read_bytes(), original)
        self.assert_clean()


if __name__ == "__main__":
    unittest.main()
