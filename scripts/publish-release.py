#!/usr/bin/env python3
"""Publish verified artifacts, then update a static gh-pages branch using GH_TOKEN."""
import argparse
import hashlib
import json
import os
import subprocess
from pathlib import Path

from importlib.util import module_from_spec, spec_from_file_location

ROOT = Path(__file__).resolve().parents[1]


def api(path, *, method="GET", data=None, optional=False):
    command = ["gh", "api", "--method", method, path]
    if data is not None:
        command += ["--input", "-"]
    result = subprocess.run(command, input=json.dumps(data) if data is not None else None,
                            capture_output=True, text=True)
    if result.returncode:
        if optional and "(HTTP 404)" in result.stderr:
            return None
        raise RuntimeError(result.stderr.strip())
    return json.loads(result.stdout) if result.stdout.strip() else None


def find_release(repository, tag):
    release = api(f"repos/{repository}/releases/tags/{tag}", optional=True)
    if release is not None:
        return release
    # GitHub can return 404 for a draft's tag before that tag has been created.
    # Drafts are visible in the authenticated release list and must be reused.
    page = 1
    while True:
        releases = api(f"repos/{repository}/releases?per_page=100&page={page}")
        matches = [item for item in releases if item["tag_name"] == tag]
        if len(matches) > 1:
            raise ValueError("Multiple drafts share this tag; inspect them before publishing")
        if matches:
            return matches[0]
        if len(releases) < 100:
            return None
        page += 1


def publish(output):
    manifest = json.loads((output / "release-manifest.json").read_text())
    repository = manifest["repository"]
    spec = spec_from_file_location("release_helpers", ROOT / "scripts/release.py")
    helpers = module_from_spec(spec)
    spec.loader.exec_module(helpers)
    helpers.valid_repository(repository)
    version = helpers.valid_version(manifest["version"])
    if manifest["notarization"]["status"] != "Accepted":
        raise ValueError("Refusing to publish an unnotarized release")
    repo = api(f"repos/{repository}")
    if repo["private"]:
        raise ValueError("Update downloads require a public release repository")
    tag = f"v{version}"
    artifacts = []
    for name, expected in manifest["artifacts"].items():
        if Path(name).name != name or not name.startswith(f"phone-use-{version}-arm64."):
            raise ValueError("Unexpected artifact name")
        path = output / name
        with path.open("rb") as stream:
            if hashlib.file_digest(stream, "sha256").hexdigest() != expected:
                raise ValueError(f"Artifact checksum mismatch: {name}")
        artifacts += [path, path.with_name(name + ".sha256")]
    artifacts.append(output / "release-manifest.json")
    release = find_release(repository, tag)
    if release is None:
        release = api(f"repos/{repository}/releases", method="POST", data={
            "tag_name": tag, "target_commitish": repo["default_branch"], "name": f"phone-use {version}",
            "draft": True, "body": "macOS 15+ · Apple Silicon\n\n已完成 Developer ID 签名和 Apple 公证。打开 DMG，将 phone-use 拖入 Applications 安装。"})
    if release["draft"]:
        print(f"Uploading {len(artifacts)} verified assets to draft {tag}...", flush=True)
        result = subprocess.run(["gh", "release", "upload", tag, "--repo", repository, "--clobber",
                                 *map(str, artifacts)], capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(result.stderr.strip())
        release = api(f"repos/{repository}/releases/{release['id']}")
    assets = {asset["name"]: asset for asset in release["assets"]}
    for name, expected in manifest["artifacts"].items():
        if name not in assets or assets[name].get("digest") != f"sha256:{expected}":
            raise ValueError("Release asset does not match this build; published releases are never overwritten")
    print("Remote archive checksums verified.", flush=True)
    if release["draft"]:
        api(f"repos/{repository}/releases/{release['id']}", method="PATCH", data={"draft": False, "make_latest": "true"})
    # The download is public before the feed can advertise it. Only static files
    # go to gh-pages, even when the source repository is private.
    branch = api(f"repos/{repository}/git/ref/heads/gh-pages", optional=True)
    tree_data = {"tree": [{"path": p.name, "mode": "100644", "type": "blob", "content": p.read_text()}
                           for p in sorted((output / "pages").iterdir()) if p.is_file()]}
    parents = []
    if branch:
        head = branch["object"]["sha"]
        commit = api(f"repos/{repository}/git/commits/{head}")
        tree_data["base_tree"] = commit["tree"]["sha"]
        parents = [head]
    tree = api(f"repos/{repository}/git/trees", method="POST", data=tree_data)
    commit = api(f"repos/{repository}/git/commits", method="POST", data={
        "message": f"Publish phone-use {version} update feed", "tree": tree["sha"], "parents": parents})
    if branch:
        api(f"repos/{repository}/git/refs/heads/gh-pages", method="PATCH", data={"sha": commit["sha"], "force": False})
    else:
        api(f"repos/{repository}/git/refs", method="POST", data={"ref": "refs/heads/gh-pages", "sha": commit["sha"]})
    print(f"Published https://github.com/{repository}/releases/tag/{tag}")
    print(f"Updated Pages feed: {manifest['feed']}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "dist")
    try:
        publish(parser.parse_args().output)
    except (ValueError, RuntimeError) as error:
        raise SystemExit(str(error))
