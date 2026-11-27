#!/usr/bin/env python3
"""Prepare the pinned standalone Node runtime, upstream MCP package and its tool catalog."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / ".build/chrome-mcp"
NODE = "node-v24.15.0-darwin-arm64"
MCP = "chrome-devtools-mcp-1.12.0"
NODE_URL = f"https://nodejs.org/dist/v24.15.0/{NODE}.tar.xz"
MCP_URL = f"https://registry.npmjs.org/chrome-devtools-mcp/-/{MCP}.tgz"
NODE_SHA256 = "af5cfaeafe603aaf7599f287fd9d100bb41f16794f49788fa59dd3f25546930f"
MCP_SHA512 = "9401a91f4cd74f565d68f79f3f528afccbf1c2284e96eed5190ee9e306e10fd3a1375eef502e0a5a4fc8994611f43138b3eeebe2bd32495e31af63a44daed930"


def archive(url, algorithm, digest, allow_download):
    path = CACHE / url.rsplit("/", 1)[1]
    if not path.exists() and allow_download:
        with tempfile.TemporaryDirectory(dir=CACHE) as temp:
            part = Path(temp) / "download"
            subprocess.run(["curl", "-fLsS", "--retry", "2", "-o", str(part), url], check=True)
            if hashlib.new(algorithm, part.read_bytes()).hexdigest() != digest:
                raise ValueError(f"Checksum mismatch for {url}")
            part.replace(path)
    if not path.is_file():
        raise SystemExit(f"Missing {path.name}. Run scripts/setup-dev.sh to prepare the PhoneUse runtime.")
    if hashlib.new(algorithm, path.read_bytes()).hexdigest() != digest:
        raise ValueError(f"Checksum mismatch for {path}")
    return path


def stage(destination, download):
    node = archive(NODE_URL, "sha256", NODE_SHA256, download)
    mcp = archive(MCP_URL, "sha512", MCP_SHA512, download)
    with tarfile.open(node) as source:
        for member, name in [("bin/node", "node"), ("LICENSE", "NODE-LICENSE")]:
            with source.extractfile(f"{NODE}/{member}") as stream, (destination / name).open("wb") as output:
                shutil.copyfileobj(stream, output)
    (destination / "node").chmod(0o755)
    with tarfile.open(mcp) as source:
        source.extractall(destination, filter="data")
    script = destination / "package/build/src/bin/chrome-devtools-mcp.js"
    requests = [{"id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18",
                 "clientInfo": {"name": "phone-use-build", "version": "1"}, "capabilities": {}}},
                {"method": "notifications/initialized"}, {"id": 2, "method": "tools/list", "params": {}}]
    with subprocess.Popen([destination / "node", script, "--wsEndpoint", "ws://127.0.0.1:1",
                           "--no-usage-statistics", "--no-performance-crux"],
                          env={**os.environ, "CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS": "1"},
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True) as child:
        for req in requests:
            child.stdin.write(json.dumps({"jsonrpc": "2.0", **req}) + "\n")
            child.stdin.flush()
            if "id" in req:
                while line := child.stdout.readline():
                    response = json.loads(line)
                    if response.get("id") == req["id"]:
                        break
                else:
                    raise ValueError("Chrome MCP stopped before returning its catalog")
        tools = response["result"]["tools"]
        if not tools or response["result"].get("nextCursor"):
            raise ValueError("Incomplete Chrome MCP tool catalog")
        (destination / "tools.json").write_text(json.dumps(tools, ensure_ascii=False))
        child.stdin.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--download", action="store_true")
    parser.add_argument("--bundle-dir", type=Path, help="embed verified archives in the PhoneUse resources")
    args = parser.parse_args()
    if args.download and args.bundle_dir:
        parser.error("Run --download before building the app")
    CACHE.mkdir(parents=True, exist_ok=True)
    destination = args.bundle_dir or CACHE / "current"
    with tempfile.TemporaryDirectory(dir=CACHE) as temp:
        staging = Path(temp)
        stage(staging, args.download)
        destination.mkdir(parents=True, exist_ok=True)
        subprocess.run(["rsync", "-a", "--delete", f"{staging}/", f"{destination}/"], check=True)
