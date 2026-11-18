#!/usr/bin/env python3
"""Build, notarize and package a Sparkle release. Does not publish to GitHub."""
import argparse
import base64
import hashlib
import html
import json
import os
import plistlib
import re
import shutil
import subprocess
import tempfile
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

from importlib.util import module_from_spec, spec_from_file_location
from typing import NamedTuple

ROOT = Path(__file__).resolve().parents[1]
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


class Product(NamedTuple):
    app_name: str
    bundle_id: str
    tag_prefix: str
    pages_directory: str

    def feed_url(self, repository):
        owner, repo = repository.split("/")
        return f"https://{owner}.github.io/{repo}/{self.pages_directory}appcast.xml"


PRODUCTS = {
    "phone-use": Product("PhoneUse", "cn.andysheng.phoneuse", "v", ""),
    "automation": Product("Automation", "cn.andysheng.automation", "automation-v", "automation/"),
}


def run(args, *, env=None, allow_failure=False):
    result = subprocess.run([str(a) for a in args], env=env, capture_output=True, text=True)
    if result.returncode and not allow_failure:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or f"{args[0]} failed")
    return result.stdout


def valid_version(value):
    if not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", value):
        raise argparse.ArgumentTypeError("version must be MAJOR.MINOR.PATCH")
    return value


def valid_repository(value):
    if (not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+", value)
            or value.split("/")[-1] in {".", ".."}):
        raise argparse.ArgumentTypeError("repository must be OWNER/REPO")
    return value


def previous_feed(url, destination, build_number, version=None):
    try:
        with urllib.request.urlopen(url, timeout=60) as response:
            data = response.read()
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return
        raise
    root = ET.fromstring(data)
    if root.tag != "rss" or root.find("channel") is None:
        raise ValueError("The existing update feed is not an RSS appcast")
    versions = [int(item.text) for item in root.findall(f"./channel/item/{SPARKLE}version")]
    if versions and build_number <= max(versions):
        raise ValueError("Build number must be greater than all published builds")
    if version:
        published = [tuple(map(int, item.text.split(".")))
                     for item in root.findall(f"./channel/item/{SPARKLE}shortVersionString")
                     if re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", item.text or "")]
        if published and tuple(map(int, version.split("."))) < max(published):
            raise ValueError("Refusing to publish a lower marketing version")
    destination.write_bytes(data)


def tolerated_notary_issue(issue):
    """Only Apple's warning that it cannot unpack the pinned scrcpy server is accepted.

    That file is a Dalvik archive pushed to Android devices, verified against its pinned digest
    before embedding, and holds no macOS code. Since 2026-11 Apple warns that it cannot unpack it;
    every other issue, and any error for that path, still fails the release.
    """
    scrcpy = json.loads((ROOT / "scripts/android-assets.json").read_text(encoding="utf-8"))["scrcpy"]["filename"]
    return (issue.get("severity") == "warning"
            and (issue.get("path") or "").endswith(f".app/Contents/Resources/android/{scrcpy}")
            and "could not be unpacked" in (issue.get("message") or ""))


def notarize(artifact, work, profile):
    auth = ["--keychain-profile", profile]
    if keychain := os.environ.get("NOTARY_KEYCHAIN"):
        auth += ["--keychain", keychain]
    print(f"Uploading {artifact.name} to Apple for notarization...", flush=True)
    submitted = json.loads(run(["xcrun", "notarytool", "submit", artifact, *auth, "--output-format", "json"]))
    submission = submitted["id"]
    (work / f"{artifact.name}.submission.json").write_text(json.dumps(submitted, indent=2))
    print(f"Uploaded {artifact.name}; notarization submission {submission}", flush=True)
    # notarytool exits nonzero for a rejected submission but still returns JSON.
    # Preserve that result and Apple's diagnostic log before reporting failure.
    result = json.loads(run(["xcrun", "notarytool", "wait", submission, *auth, "--timeout", "20m", "--output-format", "json"], allow_failure=True))
    (work / f"{artifact.name}.result.json").write_text(json.dumps(result, indent=2))
    log = work / f"{artifact.name}.notary-log.json"
    run(["xcrun", "notarytool", "log", submission, *auth, log])
    details = json.loads(log.read_text())
    if result["status"] != "Accepted" or details["status"] != "Accepted":
        raise RuntimeError(f"Apple rejected {artifact.name}; inspect {log}")
    issues = details.get("issues") or []
    for issue in filter(tolerated_notary_issue, issues):
        print(f"Tolerated notary warning: {issue.get('path')}: {issue.get('message')}", flush=True)
    if [issue for issue in issues if not tolerated_notary_issue(issue)]:
        raise RuntimeError(f"Apple reported notarization issues; inspect {log}")
    with artifact.open("rb") as stream:
        if details["sha256"] != hashlib.file_digest(stream, "sha256").hexdigest():
            raise RuntimeError("The notarized artifact checksum does not match")
    print(f"Apple accepted {artifact.name}", flush=True)
    return submission


def release(args):
    identity = os.environ.get("SIGN_IDENTITY", "")
    if not identity.startswith("Developer ID Application:"):
        raise ValueError("Set SIGN_IDENTITY to a Developer ID Application identity")
    if args.build_number < 1:
        raise ValueError("build number must be a positive integer")
    product = PRODUCTS[args.product]
    output = ROOT / "dist" / product.pages_directory
    stem = f"{args.product}-{args.version}-arm64"
    update = output / f"{stem}.zip"
    image = output / f"{stem}.dmg"
    if update.exists() or image.exists():
        raise ValueError("Release artifacts already exist; use a new version or explicitly move old artifacts aside")
    spec = spec_from_file_location("prepare_sparkle", ROOT / "scripts/prepare-sparkle.py")
    module = module_from_spec(spec)
    spec.loader.exec_module(module)
    tools = module.prepare()
    cache = ROOT / ".build/releases"
    cache.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix=f"{args.product}-{args.version}-{args.build_number}-", dir=cache))
    print(f"Release workspace: {work}", flush=True)
    feed = work / "feed"
    feed.mkdir()
    # Reject downgrades before performing an expensive build or notarization.
    expected_feed = product.feed_url(args.repository)
    previous_feed(expected_feed, feed / "appcast.xml", args.build_number, args.version)
    environment = os.environ.copy()
    environment.update(VERSION=args.version, BUILD_NUMBER=str(args.build_number), NOTARY_PROFILE="")
    if not args.skip_build:
        # Keep build output in the existing log; do not hide build failures.
        subprocess.run([str(ROOT / "scripts/build-app.sh"), args.product], env=environment, check=True)
    app = ROOT / "dist" / f"{product.app_name}.app"
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info["CFBundleIdentifier"] != product.bundle_id:
        raise ValueError("The built app's bundle identifier does not match the requested product")
    if info["CFBundleShortVersionString"] != args.version or info["CFBundleVersion"] != str(args.build_number):
        raise ValueError("The built app's version/build does not match the requested release")
    if len(base64.b64decode(info.get("SUPublicEDKey", ""), validate=True)) != 32:
        raise ValueError("Missing or invalid Sparkle public key")
    feed_url = info["SUFeedURL"]
    if feed_url != expected_feed:
        raise ValueError("The app's feed URL must match the configured public release repository")
    run(["codesign", "--verify", "--deep", "--strict", app])
    preflight = work / "notary-app.zip"
    run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, preflight])
    app_submission = notarize(preflight, work, args.notary_profile)
    run(["xcrun", "stapler", "staple", app])
    run(["xcrun", "stapler", "validate", app])
    output.mkdir(parents=True, exist_ok=True)
    run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, update])
    stage = work / "image"
    stage.mkdir()
    run(["ditto", app, stage / app.name])
    (stage / "Applications").symlink_to("/Applications", target_is_directory=True)
    run(["hdiutil", "create", "-volname", product.app_name, "-srcfolder", stage, "-format", "UDZO", "-fs", "HFS+", image])
    run(["codesign", "--force", "--sign", identity, "--timestamp", "--identifier", f"{product.bundle_id}.dmg", image])
    dmg_submission = notarize(image, work, args.notary_profile)
    run(["xcrun", "stapler", "staple", image])
    run(["xcrun", "stapler", "validate", image])
    run(["spctl", "--assess", "--type", "execute", app])
    run(["spctl", "--assess", "--type", "open", "--context", "context:primary-signature", image])
    run(["syspolicy_check", "distribution", app])
    shutil.copy2(update, feed / update.name)
    notes = args.release_notes.read_text() if args.release_notes else f"{product.app_name} {args.version}"
    (feed / f"{stem}.html").write_text("<p>" + html.escape(notes).replace("\n", "<br>\n") + "</p>\n")
    signing = (["--ed-key-file", args.sparkle_key] if args.sparkle_key else ["--account", "phone-use"])
    download = f"https://github.com/{args.repository}/releases/download/{product.tag_prefix}{args.version}/"
    run([tools / "generate_appcast", *signing, "--download-url-prefix", download,
         "--release-notes-url-prefix", feed_url.removesuffix("appcast.xml"),
         "--versions", str(args.build_number), "--maximum-deltas", "0", feed])
    run([tools / "sign_update", "--verify", *signing, feed / "appcast.xml"])
    publish = output / "pages"
    publish.mkdir(exist_ok=True)
    shutil.copy2(feed / "appcast.xml", publish / "appcast.xml")
    shutil.copy2(feed / f"{stem}.html", publish / f"{stem}.html")
    if not product.pages_directory:
        (publish / ".nojekyll").touch()
    (publish / "index.html").write_text(
        f'<!doctype html><meta charset="utf-8"><title>{product.app_name}</title><h1>{product.app_name}</h1>'
        f'<p><a href="{download}{image.name}">下载 macOS Apple Silicon 版本 {args.version}</a></p>'
        f'<p>需要 macOS 15 或更新版本。打开 DMG 后将 {product.app_name} 拖入 Applications。</p>'
        '<p><a href="appcast.xml">自动更新清单</a></p>\n')
    hashes = {}
    for artifact in [update, image]:
        with artifact.open("rb") as stream:
            hashes[artifact.name] = hashlib.file_digest(stream, "sha256").hexdigest()
        artifact.with_name(artifact.name + ".sha256").write_text(f"{hashes[artifact.name]}  {artifact.name}\n")
    source_commit = run(["git", "-C", ROOT, "rev-parse", "HEAD"]).strip()
    metadata = {"product": args.product, "source_commit": source_commit,
                "version": args.version, "build": args.build_number, "artifacts": hashes,
                "notarization": {"app": app_submission, "dmg": dmg_submission, "status": "Accepted"},
                "feed": feed_url, "repository": args.repository}
    (output / "release-manifest.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(f"Release verified. Archives: {output}; Pages files: {publish}", flush=True)


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--product", choices=PRODUCTS, default="phone-use")
    result.add_argument("--version", required=True, type=valid_version)
    result.add_argument("--build-number", required=True, type=int)
    result.add_argument("--repository", required=True, type=valid_repository)
    result.add_argument("--notary-profile", default="phone-use-notary")
    result.add_argument("--sparkle-key", type=Path, help="CI-only private key file; local releases use the Keychain")
    result.add_argument("--release-notes", type=Path)
    result.add_argument("--skip-build", action="store_true")
    return result


if __name__ == "__main__":
    try:
        release(parser().parse_args())
    except (ValueError, RuntimeError) as error:
        raise SystemExit(str(error))
