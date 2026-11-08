#!/usr/bin/env python3
"""Developer ID sign native code and nested bundles from the inside out."""
import argparse
import plistlib
import struct
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ENDIAN = {b"\xfe\xed\xfa\xce": ">", b"\xce\xfa\xed\xfe": "<",
          b"\xfe\xed\xfa\xcf": ">", b"\xcf\xfa\xed\xfe": "<"}


def native_code(path):
    with path.open("rb") as stream:
        header = stream.read(32)
    if len(header) < 16:
        return False
    if header[:4] in ENDIAN:
        return struct.unpack(ENDIAN[header[:4]] + "I", header[12:16])[0] in {2, 6, 8}
    if header[:4] in {b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"}:
        return 0 < struct.unpack(">I", header[4:8])[0] <= 32
    return False


def run(*args):
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or f"{args[0]} failed")
    return result.stdout + result.stderr


def sign(app, identity):
    if not identity.startswith("Developer ID Application:"):
        raise ValueError("Release signing requires a Developer ID Application identity")
    base = ["codesign", "--force", "--sign", identity, "--options", "runtime", "--timestamp"]
    native = sorted(p for p in app.rglob("*") if p.is_file() and not p.is_symlink() and native_code(p))
    if not native:
        raise ValueError("No native executables found")
    python_bin = app / "Contents/Resources/python/bin"
    for index, path in enumerate(native, 1):
        # Apply only the runtime permissions we own; cached ad-hoc CLI builds
        # can carry get-task-allow, which must never survive a release re-sign.
        options = (["--entitlements", str(ROOT / "Support/Python.entitlements")]
                   if path.parent == python_bin else ["--preserve-metadata=identifier"])
        run(*base, *options, str(path))
        if index % 25 == 0:
            print(f"Signed {index}/{len(native)} native files", flush=True)
    bundles = sorted((p for p in app.rglob("*") if p.is_dir() and not p.is_symlink()
                      and (p.suffix == ".framework" or
                           (p.suffix in {".app", ".xpc", ".bundle"} and (p / "Contents/Info.plist").exists()))),
                     key=lambda p: len(p.parts), reverse=True)
    for bundle in bundles:
        run(*base, "--preserve-metadata=identifier", str(bundle))
    run(*base, "--entitlements", str(ROOT / "Support/DeviceHub.entitlements"), str(app))
    run("codesign", "--verify", "--deep", "--strict", str(app))
    for path in [*native, app]:
        details = run("codesign", "--display", "--verbose=4", str(path))
        if f"Authority={identity}" not in details or "Timestamp=" not in details or "(runtime)" not in details:
            raise RuntimeError(f"Incomplete Developer ID signature: {path.relative_to(app)}")
        run("codesign", "--verify", "--strict", str(path))
        result = subprocess.run(["codesign", "--display", "--entitlements", ":-", str(path)], capture_output=True)
        if result.stdout.strip().startswith(b"<?xml") and plistlib.loads(result.stdout).get("com.apple.security.get-task-allow"):
            raise RuntimeError(f"Debug entitlement in release: {path}")
    print(f"Verified Developer ID signatures, hardened runtime and timestamps for {len(native)} native files and the app")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("identity")
    args = parser.parse_args()
    sign(args.app.resolve(), args.identity)
