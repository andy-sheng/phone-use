#!/usr/bin/env python3
"""Fetch pinned official Sparkle release tools; never download signing keys."""
import hashlib
import json
import tarfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def prepare():
    manifest = json.loads((ROOT / "scripts/sparkle-assets.json").read_text())
    cache = ROOT / ".build/sparkle"
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / f"Sparkle-{manifest['version']}.tar.xz"
    if not archive.exists():
        temporary = archive.with_suffix(".part")
        with urllib.request.urlopen(manifest["url"], timeout=120) as source, temporary.open("wb") as target:
            while chunk := source.read(1024 * 1024):
                target.write(chunk)
        temporary.replace(archive)
    with archive.open("rb") as stream:
        if hashlib.file_digest(stream, "sha256").hexdigest() != manifest["sha256"]:
            raise RuntimeError("Sparkle archive SHA-256 mismatch; remove the invalid cached archive and retry")
    destination = cache / manifest["version"]
    if not (destination / "bin/generate_appcast").exists():
        destination.mkdir(exist_ok=True)
        with tarfile.open(archive) as bundle:
            bundle.extractall(destination, filter="data")
    return destination / "bin"


if __name__ == "__main__":
    print(prepare())
