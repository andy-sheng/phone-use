#!/usr/bin/env python3
"""Prepare the pinned scrcpy server; bundle mode never accesses the network."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


SCRIPT_DIR = Path(__file__).resolve().parent
ROOT = SCRIPT_DIR.parent
MANIFEST = SCRIPT_DIR / "android-assets.json"


def verify(path: Path, expected: str) -> None:
    if not path.is_file():
        raise ValueError(f"Missing scrcpy asset: {path}")
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if digest != expected:
        raise ValueError(f"SHA256 mismatch for {path}: expected {expected}, got {digest}")


def download(asset: dict, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=destination.parent, prefix=destination.name + ".", suffix=".part", delete=False) as handle:
        partial = Path(handle.name)
    try:
        print(f"Downloading official scrcpy server {asset['version']} to {destination}", flush=True)
        subprocess.run([
            "curl", "--fail", "--location", "--retry", "2", "--connect-timeout", "15",
            "--max-time", "90", "--output", str(partial), asset["url"],
        ], check=True)
        verify(partial, asset["sha256"])
        partial.replace(destination)
    finally:
        partial.unlink(missing_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--download", action="store_true", help="explicitly allow downloading the official server to the development cache")
    parser.add_argument("--server", type=Path, help="use this local server (same pinned version and SHA256 required); otherwise DEVICEHUB_SCRCPY_SERVER is honored")
    parser.add_argument("--cache-dir", type=Path, default=ROOT / ".build" / "android")
    parser.add_argument("--bundle-dir", type=Path, help="verify and copy the server, license, notice and manifest here, without downloading")
    args = parser.parse_args()
    if args.download and args.bundle_dir:
        parser.error("--download cannot be combined with --bundle-dir; prepare assets before building")

    asset = json.loads(MANIFEST.read_text(encoding="utf-8"))["scrcpy"]
    license_file = SCRIPT_DIR / asset["license_file"]
    notice_file = SCRIPT_DIR / asset["notice_file"]
    verify(license_file, asset["license_sha256"])
    if not notice_file.is_file():
        raise ValueError(f"Missing scrcpy attribution notice: {notice_file}")

    override = args.server or os.environ.get("DEVICEHUB_SCRCPY_SERVER")
    source = Path(override).expanduser() if override else args.cache_dir / asset["filename"]
    try:
        verify(source, asset["sha256"])
    except ValueError as error:
        if override or not args.download:
            raise ValueError(
                f"{error}\nOnly the official scrcpy {asset['version']} server is accepted. "
                "Run python3 scripts/prepare-android-video.py --download before building, "
                "or set DEVICEHUB_SCRCPY_SERVER to a verified local copy."
            ) from error
        download(asset, source)

    print(f"Verified scrcpy server {asset['version']}: {source}")
    if args.bundle_dir:
        args.bundle_dir.mkdir(parents=True, exist_ok=True)
        destination = args.bundle_dir / asset["filename"]
        if source.resolve() != destination.resolve():
            shutil.copyfile(source, destination)
        verify(destination, asset["sha256"])
        shutil.copyfile(license_file, args.bundle_dir / "LICENSE")
        shutil.copyfile(notice_file, args.bundle_dir / "NOTICE")
        shutil.copyfile(MANIFEST, args.bundle_dir / "android-assets.json")
        print(f"Embedded scrcpy server {asset['version']} and license into {args.bundle_dir}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
