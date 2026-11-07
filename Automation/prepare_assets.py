"""Prepare pinned runtime or plugin resources, reusing verified local assets."""

import argparse
import hashlib
import json
import shutil
import urllib.request
from pathlib import Path


def git_blob_hash(data: bytes) -> str:
    return hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()


def prepare(output: Path, manifest_path: Path | None = None, cache: Path | None = None) -> None:
    manifest = json.loads((manifest_path or Path(__file__).with_name("assets.json")).read_text())
    output.mkdir(parents=True, exist_ok=True)
    for item in manifest["files"]:
        target = (output / item["destination"]).resolve()
        if not target.is_relative_to(output.resolve()):
            raise ValueError("Asset destination is outside the resource directory")
        if target.is_file() and git_blob_hash(target.read_bytes()) == item["blob_sha"]:
            continue
        cached = cache / item["destination"] if cache else None
        if cached and cached.is_file() and git_blob_hash(cached.read_bytes()) == item["blob_sha"]:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(cached, target)
            continue
        url = f"https://raw.githubusercontent.com/{item['repository']}/{item['commit']}/{item['path']}"
        print(f"Downloading {item['destination']}", flush=True)
        with urllib.request.urlopen(url, timeout=90) as response:
            data = response.read()
        if git_blob_hash(data) != item["blob_sha"]:
            raise ValueError(f"Asset checksum mismatch: {item['path']}")
        target.parent.mkdir(parents=True, exist_ok=True)
        temporary = target.with_name(target.name + ".part")
        temporary.write_bytes(data)
        temporary.replace(target)
    (output / "provenance.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
    print(f"Assets ready: {output.resolve()}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--cache", type=Path)
    args = parser.parse_args()
    prepare(args.output, args.manifest, args.cache)
