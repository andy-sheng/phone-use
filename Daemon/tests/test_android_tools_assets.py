"""Offline tests for preparing and packaging the standalone ADB dependency."""

import hashlib
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile


SCRIPT = Path(__file__).resolve().parents[2] / "scripts/prepare-android-tools.py"
SPEC = importlib.util.spec_from_file_location("prepare_android_tools", SCRIPT)
tools = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(tools)


class AndroidToolsAssetsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.cache = self.root / "cache"
        self.archive = self.root / "platform-tools-test.zip"
        self.files = {
            "adb": b"#!/bin/sh\nexit 0\n",
            "lib64/libc++.dylib": b"runtime library fixture",
            "NOTICE.txt": b"upstream license fixture",
            "source.properties": b"Pkg.Revision=test\n",
        }
        with zipfile.ZipFile(self.archive, "w") as bundle:
            for name, data in self.files.items():
                bundle.writestr("platform-tools/" + name, data)
            bundle.writestr("platform-tools/fastboot", b"unneeded utility")
            bundle.writestr("../outside-cache", b"must not be extracted")
        self.asset = {
            "version": "test",
            "filename": self.archive.name,
            "url": "https://example.invalid/platform-tools-test.zip",
            "sha256": hashlib.sha256(self.archive.read_bytes()).hexdigest(),
            "files": {name: hashlib.sha256(data).hexdigest() for name, data in self.files.items()},
        }

    def test_offline_archive_prepares_executable_and_licenses_only(self):
        directory = tools.prepare(self.asset, self.cache, archive=self.archive)
        self.assertEqual(directory, self.cache / "platform-tools")
        self.assertEqual({p.relative_to(directory).as_posix() for p in directory.rglob("*") if p.is_file()}, set(self.files))
        self.assertEqual((directory / "adb").stat().st_mode & 0o777, 0o755)
        self.assertEqual((directory / "NOTICE.txt").read_bytes(), self.files["NOTICE.txt"])
        self.assertFalse((self.root / "outside-cache").exists())

    def test_verified_cache_needs_neither_archive_nor_network(self):
        directory = tools.prepare(self.asset, self.cache, archive=self.archive)
        self.archive.unlink()
        with patch.object(tools.subprocess, "run") as run:
            self.assertEqual(tools.prepare(self.asset, self.cache, allow_download=True), directory)
        run.assert_not_called()

    def test_missing_cache_fails_offline_with_preparation_command(self):
        with patch.object(tools.subprocess, "run") as run:
            with self.assertRaisesRegex(ValueError, "prepare-android-tools.py --download"):
                tools.prepare(self.asset, self.cache)
        run.assert_not_called()

    def test_tampered_cache_is_repaired_from_verified_cached_archive(self):
        directory = tools.prepare(self.asset, self.cache, archive=self.archive)
        cached_archive = self.cache / self.asset["filename"]
        cached_archive.write_bytes(self.archive.read_bytes())
        (directory / "adb").write_bytes(b"tampered executable")
        with patch.object(tools.subprocess, "run") as run:
            tools.prepare(self.asset, self.cache)
        run.assert_not_called()
        self.assertEqual((directory / "adb").read_bytes(), self.files["adb"])

    def test_cached_adb_without_execute_permission_is_repaired(self):
        directory = tools.prepare(self.asset, self.cache, archive=self.archive)
        (self.cache / self.asset["filename"]).write_bytes(self.archive.read_bytes())
        (directory / "adb").chmod(0o644)
        tools.prepare(self.asset, self.cache)
        self.assertEqual((directory / "adb").stat().st_mode & 0o777, 0o755)

    def test_wrong_explicit_archive_is_rejected_even_with_valid_cache(self):
        directory = tools.prepare(self.asset, self.cache, archive=self.archive)
        self.archive.write_bytes(b"different version")
        with self.assertRaisesRegex(ValueError, "SHA256 mismatch"):
            tools.prepare(self.asset, self.cache, archive=self.archive)
        self.assertEqual((directory / "adb").read_bytes(), self.files["adb"])

    def test_download_is_verified_then_reused(self):
        def fetch(command, **kwargs):
            Path(command[command.index("--output") + 1]).write_bytes(self.archive.read_bytes())

        with patch.object(tools.subprocess, "run", side_effect=fetch) as run:
            directory = tools.prepare(self.asset, self.cache, allow_download=True)
        self.assertEqual(run.call_args.args[0][-1], self.asset["url"])
        self.assertEqual((directory / "adb").read_bytes(), self.files["adb"])
        self.assertEqual((self.cache / self.asset["filename"]).read_bytes(), self.archive.read_bytes())
        self.assertEqual(list(self.cache.glob("*.part")), [])

    def test_corrupt_or_interrupted_download_cannot_replace_cache(self):
        for interrupted in (False, True):
            with self.subTest(interrupted=interrupted):
                self.cache.mkdir(exist_ok=True)
                archive = self.cache / self.asset["filename"]
                archive.write_bytes(b"previous archive")

                def fetch(command, **kwargs):
                    Path(command[command.index("--output") + 1]).write_bytes(b"partial download")
                    if interrupted:
                        raise subprocess.CalledProcessError(7, command)

                with patch.object(tools.subprocess, "run", side_effect=fetch):
                    with self.assertRaises((ValueError, subprocess.CalledProcessError)):
                        tools.prepare(self.asset, self.cache, allow_download=True)
                self.assertEqual(archive.read_bytes(), b"previous archive")
                self.assertFalse((self.cache / "platform-tools").exists())
                self.assertEqual(list(self.cache.glob("*.part")), [])

    def test_changed_extracted_files_are_rejected_before_replacing_tools(self):
        directory = tools.prepare(self.asset, self.cache, archive=self.archive)
        bad_asset = {**self.asset, "files": {**self.asset["files"], "NOTICE.txt": "0" * 64}}
        with self.assertRaisesRegex(ValueError, "SHA256 mismatch"):
            tools.prepare(bad_asset, self.cache, archive=self.archive)
        self.assertEqual((directory / "NOTICE.txt").read_bytes(), self.files["NOTICE.txt"])

    def test_bundle_copies_licenses_and_library_and_removes_stale_files(self):
        directory = tools.prepare(self.asset, self.cache, archive=self.archive)
        destination = self.root / "app/android/platform-tools"
        destination.mkdir(parents=True)
        (destination / "old-library.dylib").write_bytes(b"old library")
        tools.embed(directory, destination, self.asset)
        self.assertEqual({p.relative_to(destination).as_posix() for p in destination.rglob("*") if p.is_file()}, set(self.files))
        tools.verify_tools(destination, self.asset)
        (directory / "NOTICE.txt").write_bytes(b"changed notice")
        with self.assertRaisesRegex(ValueError, "SHA256 mismatch"):
            tools.embed(directory, destination, self.asset)
        self.assertEqual((destination / "NOTICE.txt").read_bytes(), self.files["NOTICE.txt"])


if __name__ == "__main__":
    unittest.main()
