import hashlib
import importlib.util
import io
import json
import tempfile
import unittest
import urllib.error
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), Path(__file__).parents[1] / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


release = load("release")
publisher = load("publish-release")


class ReleaseTests(unittest.TestCase):
    def test_rejected_notarization_preserves_apples_diagnostic_log(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            artifact = work / "update.zip"
            artifact.write_bytes(b"rejected archive")
            commands = []

            def execute(command, **kwargs):
                operation = command[2]
                commands.append(operation)
                if operation == "submit":
                    return SimpleNamespace(returncode=0, stdout='{"id":"submission-id"}', stderr="")
                if operation == "wait":
                    return SimpleNamespace(returncode=1, stdout='{"status":"Invalid"}', stderr="Rejected")
                Path(command[-1]).write_text('{"status":"Invalid","issues":[{"message":"Invalid signature"}]}')
                return SimpleNamespace(returncode=0, stdout="", stderr="")

            with patch.object(release.subprocess, "run", side_effect=execute):
                with self.assertRaisesRegex(RuntimeError, "Apple rejected"):
                    release.notarize(artifact, work, "test-profile")
            self.assertEqual(commands, ["submit", "wait", "log"])
            self.assertTrue((work / "update.zip.notary-log.json").exists())

    def test_initial_feed_404_is_allowed_but_server_errors_are_not(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "appcast.xml"
            for status in [404, 500]:
                error = urllib.error.HTTPError("https://example.test/appcast.xml", status, "error", {}, None)
                with patch.object(release.urllib.request, "urlopen", side_effect=error):
                    if status == 404:
                        release.previous_feed("https://example.test/appcast.xml", destination, 10)
                        self.assertFalse(destination.exists())
                    else:
                        with self.assertRaises(urllib.error.HTTPError):
                            release.previous_feed("https://example.test/appcast.xml", destination, 10)

    def test_existing_versions_cannot_be_overwritten_or_downgraded(self):
        feed = b'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>1002</sparkle:version></item></channel></rss>'
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "appcast.xml"
            for version in [1, 1002]:
                with patch.object(release.urllib.request, "urlopen", return_value=io.BytesIO(feed)):
                    with self.assertRaises(ValueError):
                        release.previous_feed("https://example.test/appcast.xml", destination, version)
            with patch.object(release.urllib.request, "urlopen", return_value=io.BytesIO(feed)):
                release.previous_feed("https://example.test/appcast.xml", destination, 1003)
            self.assertEqual(destination.read_bytes(), feed)

    def test_version_and_repository_inputs_reject_shell_and_path_payloads(self):
        for value in ["v0.3.0", "0.3.0; echo secret", "../0.3.0", "0.3", "01.3.0"]:
            with self.assertRaises(Exception):
                release.valid_version(value)
        for value in ["../private", "owner/repo/../../secret", "owner/repo\nother", "owner/repo;command"]:
            with self.assertRaises(Exception):
                release.valid_repository(value)


class PublishTests(unittest.TestCase):
    def test_a_draft_is_reused_when_its_unpublished_tag_returns_404(self):
        draft = {"id": 42, "tag_name": "v0.3.0", "draft": True}
        with patch.object(publisher, "api", side_effect=[None, [draft]]) as api:
            self.assertEqual(publisher.find_release("owner/releases", "v0.3.0"), draft)
        self.assertEqual(api.call_count, 2)
        self.assertIn("per_page=100", api.call_args.args[0])

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.output = Path(self.temporary.name)
        name = "phone-use-0.3.0-arm64.zip"
        (self.output / name).write_bytes(b"signed release fixture")
        digest = hashlib.sha256((self.output / name).read_bytes()).hexdigest()
        (self.output / f"{name}.sha256").write_text(digest)
        self.manifest = {"repository": "owner/releases", "version": "0.3.0", "build": 1001,
                         "notarization": {"status": "Accepted"}, "artifacts": {name: digest},
                         "feed": "https://owner.github.io/releases/appcast.xml"}
        (self.output / "release-manifest.json").write_text(json.dumps(self.manifest))
        pages = self.output / "pages"
        pages.mkdir()
        (pages / "appcast.xml").write_text("<rss/>")
        (pages / ".nojekyll").touch()
        self.assets = [{"name": name, "digest": f"sha256:{digest}"}]

    def test_release_becomes_public_before_the_feed_is_updated(self):
        events = []

        def api(path, *, method="GET", data=None, optional=False):
            events.append((path, method, data))
            if path == "repos/owner/releases":
                return {"private": False, "default_branch": "main"}
            if "/releases/tags/" in path:
                return {"id": 1, "draft": True, "assets": self.assets}
            if path.endswith("/releases/1"):
                return {"id": 1, "draft": method != "PATCH", "assets": self.assets}
            if "/git/ref/heads/" in path:
                return None
            if path.endswith("/git/trees") or path.endswith("/git/commits"):
                return {"sha": "public-static-content"}
            return {}

        class Uploaded:
            returncode = 0
            stderr = ""

        with patch.object(publisher, "api", side_effect=api), patch.object(publisher.subprocess, "run", return_value=Uploaded()):
            publisher.publish(self.output)
        published = next(i for i, e in enumerate(events) if e[1] == "PATCH" and "/releases/1" in e[0])
        feed_write = next(i for i, e in enumerate(events) if e[0].endswith("/git/trees"))
        self.assertLess(published, feed_write)
        tree = events[feed_write][2]
        self.assertEqual({item["path"] for item in tree["tree"]}, {"appcast.xml", ".nojekyll"})

    def test_published_assets_with_different_hashes_never_update_the_feed(self):
        events = []

        def api(path, **kwargs):
            events.append(path)
            if path == "repos/owner/releases":
                return {"private": False, "default_branch": "main"}
            return {"id": 1, "draft": False, "assets": [{"name": self.assets[0]["name"], "digest": "sha256:wrong"}]}

        with patch.object(publisher, "api", side_effect=api):
            with self.assertRaises(ValueError):
                publisher.publish(self.output)
        self.assertFalse(any("/git/" in path for path in events))

    def test_an_unnotarized_manifest_never_contacts_github(self):
        self.manifest["notarization"]["status"] = "In Progress"
        (self.output / "release-manifest.json").write_text(json.dumps(self.manifest))
        with patch.object(publisher, "api") as api:
            with self.assertRaises(ValueError):
                publisher.publish(self.output)
            api.assert_not_called()


if __name__ == "__main__":
    unittest.main()
