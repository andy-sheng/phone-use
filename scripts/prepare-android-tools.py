#!/usr/bin/env python3
"""Prepare pinned macOS ADB and its runtime library; bundle mode stays offline."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile


SCRIPT_DIR = Path(__file__).resolve().parent
ROOT = SCRIPT_DIR.parent
MANIFEST = SCRIPT_DIR / "android-assets.json"
PREPARE_HELP = (
    "Run scripts/setup-dev.sh or python3 scripts/prepare-android-tools.py --download "
    "before building. For offline preparation, use --archive <official-platform-tools.zip>."
)


def verify(path: Path, expected: str) -> None:
    if not path.is_file():
        raise ValueError(f"Missing Android platform-tools asset: {path}")
    if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        raise ValueError(f"SHA256 mismatch for Android platform-tools asset: {path}")


def verify_tools(directory: Path, asset: dict) -> None:
    for name, digest in asset["files"].items():
        verify(directory / name, digest)
    if not os.access(directory / "adb", os.X_OK):
        raise ValueError(f"ADB is not executable: {directory / 'adb'}")


def download(asset: dict, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=destination.parent, prefix=destination.name + ".", suffix=".part", delete=False) as handle:
        partial = Path(handle.name)
    try:
        print(f"Downloading official Android Platform-Tools {asset['version']} to {destination}", flush=True)
        subprocess.run([
            "curl", "--fail", "--location", "--retry", "2", "--connect-timeout", "15",
            "--max-time", "180", "--output", str(partial), asset["url"],
        ], check=True)
        verify(partial, asset["sha256"])
        partial.replace(destination)
    finally:
        partial.unlink(missing_ok=True)


def prepare(asset: dict, cache: Path, *, allow_download: bool = False, archive: Path | None = None) -> Path:
    tools = cache / "platform-tools"
    # Verify extracted files as well as the archive so stale or modified caches cannot
    # silently enter a release. An explicit archive is always checked, even on cache hits.
    if archive is None:
        try:
            verify_tools(tools, asset)
            return tools
        except ValueError:
            pass
    source = archive if archive is not None else cache / asset["filename"]
    try:
        verify(source, asset["sha256"])
    except ValueError as error:
        if archive is not None or not allow_download:
            raise ValueError(f"{error}\n{PREPARE_HELP}") from error
        download(asset, source)

    cache.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=cache, prefix="platform-tools-") as temporary:
        staged = Path(temporary) / "platform-tools"
        with zipfile.ZipFile(source) as bundle:
            # Read only the allowlisted ADB files. Do not extract paths, symlinks or
            # unrelated utilities (fastboot, filesystem tools) from the ZIP.
            for name in asset["files"]:
                member = f"platform-tools/{name}"
                entries = [entry for entry in bundle.infolist() if entry.filename == member]
                if len(entries) != 1 or stat.S_IFMT(entries[0].external_attr >> 16) not in (0, stat.S_IFREG):
                    raise ValueError(f"Expected one regular file in Android platform-tools archive: {member}")
                target = staged / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(bundle.read(entries[0]))
                target.chmod(0o755 if name == "adb" or name.endswith(".dylib") else 0o644)
        verify_tools(staged, asset)
        if tools.exists():
            shutil.rmtree(tools)
        staged.replace(tools)
    return tools


def embed(tools: Path, destination: Path, asset: dict) -> None:
    verify_tools(tools, asset)
    if tools.resolve() == destination.resolve():
        raise ValueError("Bundle destination must differ from the Android platform-tools cache")
    if destination.exists():
        shutil.rmtree(destination)
    for name in asset["files"]:
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(tools / name, target)
    verify_tools(destination, asset)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--download", action="store_true", help="explicitly allow downloading the pinned official macOS archive")
    parser.add_argument("--archive", type=Path, help="prepare from a local official ZIP (pinned SHA256 required)")
    parser.add_argument("--cache-dir", type=Path, default=ROOT / ".build" / "android")
    parser.add_argument("--bundle-dir", type=Path, help="verify and copy ADB, lib64, upstream notices and version into this Android assets directory, without downloading")
    args = parser.parse_args()
    if args.download and (args.bundle_dir or args.archive):
        parser.error("--download cannot be combined with --bundle-dir or --archive; prepare assets before building")

    asset = json.loads(MANIFEST.read_text(encoding="utf-8"))["platform_tools"]
    tools = prepare(asset, args.cache_dir.expanduser(), allow_download=args.download,
                    archive=args.archive.expanduser() if args.archive else None)
    print(f"Verified Android Platform-Tools {asset['version']}: {tools}")
    if args.bundle_dir:
        embed(tools, args.bundle_dir / "platform-tools", asset)
        print(f"Embedded Android Platform-Tools {asset['version']} and upstream licenses into {args.bundle_dir}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
