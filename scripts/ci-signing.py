#!/usr/bin/env python3
"""Prepare/clean an ephemeral CI keychain. Never log secret values."""
import base64
import json
import os
import secrets
import shlex
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DIRECTORY = ROOT / ".build/ci-signing"


def run(args, *, stdin=None):
    result = subprocess.run(args, input=stdin, capture_output=True, text=True)
    if result.returncode:
        # CalledProcessError includes command arguments, which may contain passwords.
        raise RuntimeError(f"{Path(args[0]).name} failed (exit {result.returncode})")
    return result.stdout


def prepare():
    os.umask(0o077)
    required = ["DEVELOPER_ID_P12", "DEVELOPER_ID_P12_PASSWORD", "APPLE_ID", "APPLE_TEAM_ID",
                "APPLE_APP_SPECIFIC_PASSWORD", "SPARKLE_PRIVATE_KEY"]
    missing = [key for key in required if not os.environ.get(key)]
    if missing:
        raise ValueError("Missing Actions secrets: " + ", ".join(missing))
    DIRECTORY.mkdir(parents=True, exist_ok=True)
    original = shlex.split(run(["security", "list-keychains", "-d", "user"]))
    (DIRECTORY / "original-keychains.json").write_text(json.dumps(original))
    keychain = DIRECTORY / "release.keychain-db"
    password = secrets.token_urlsafe(32)
    run(["security", "create-keychain", "-p", password, str(keychain)])
    run(["security", "set-keychain-settings", "-lut", "21600", str(keychain)])
    run(["security", "unlock-keychain", "-p", password, str(keychain)])
    run(["security", "list-keychains", "-d", "user", "-s", str(keychain), *original])
    certificate = DIRECTORY / "certificate.p12"
    certificate.write_bytes(base64.b64decode(os.environ["DEVELOPER_ID_P12"], validate=True))
    run(["security", "import", str(certificate), "-k", str(keychain), "-P",
         os.environ["DEVELOPER_ID_P12_PASSWORD"], "-T", "/usr/bin/codesign", "-T", "/usr/bin/security"])
    certificate.unlink()
    run(["security", "set-key-partition-list", "-S", "apple-tool:,apple:", "-s", "-k", password, str(keychain)])
    identities = run(["security", "find-identity", "-v", "-p", "codesigning", str(keychain)])
    import re
    matches = re.findall(r'"(Developer ID Application: [^"\n]+)"', identities)
    if len(matches) != 1 or not matches[0].endswith(f"({os.environ['APPLE_TEAM_ID']})"):
        raise RuntimeError("The CI certificate must contain exactly one Developer ID Application identity for the selected team")
    profile = "phone-use-ci"
    run(["xcrun", "notarytool", "store-credentials", profile, "--keychain", str(keychain),
         "--apple-id", os.environ["APPLE_ID"], "--team-id", os.environ["APPLE_TEAM_ID"],
         "--password", os.environ["APPLE_APP_SPECIFIC_PASSWORD"]])
    sparkle = DIRECTORY / "sparkle.key"
    sparkle.write_text(os.environ["SPARKLE_PRIVATE_KEY"].strip() + "\n")
    with Path(os.environ["GITHUB_ENV"]).open("a") as environment:
        for name, value in {"SIGN_IDENTITY": matches[0], "NOTARY_KEYCHAIN": str(keychain),
                            "NOTARY_PROFILE": profile, "SPARKLE_KEY_FILE": str(sparkle)}.items():
            environment.write(f"{name}={value}\n")
    print("Ephemeral signing keychain and notarization credentials prepared.")


def clean():
    original = DIRECTORY / "original-keychains.json"
    if original.exists():
        run(["security", "list-keychains", "-d", "user", "-s", *json.loads(original.read_text())])
    keychain = DIRECTORY / "release.keychain-db"
    if keychain.exists():
        run(["security", "delete-keychain", str(keychain)])
    for name in ["sparkle.key", "certificate.p12", "original-keychains.json"]:
        (DIRECTORY / name).unlink(missing_ok=True)
    print("Ephemeral signing material removed.")


if __name__ == "__main__":
    try:
        clean() if sys.argv[1:] == ["clean"] else prepare()
    except (ValueError, RuntimeError) as error:
        raise SystemExit(str(error))
