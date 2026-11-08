#!/bin/zsh
# Builds dist/phone-use.app from the Xcode project (generated from project.yml): the app, its
# MCP server and CLI in Contents/Helpers, and the embedded Python daemon runtime.
# Building needs Xcode; running the result does not.
#
#   SIGN_IDENTITY   e.g. "Developer ID Application: Example (TEAMID)"; ad-hoc by default
#   TEAM_ID         development team for SIGN_IDENTITY
#   NOTARY_PROFILE  notarytool keychain profile; when set the app is notarized and stapled
#   VERSION / BUILD_NUMBER  optional release metadata overrides
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
DERIVED=${DERIVED_DATA:-$ROOT/.build/xcode}
APP=$ROOT/dist/phone-use.app

# Fail before compilation if Android assets have not been prepared. Release builds
# never download them; setup-dev.sh owns dependency preparation.
ASSET_PYTHON=${PYTHON:-python3}
if [[ -x "$ROOT/.venv-daemon/bin/python" ]]; then ASSET_PYTHON="$ROOT/.venv-daemon/bin/python"; fi
if [[ -z "${DEVICEHUB_ADB:-}" ]]; then
    "$ASSET_PYTHON" "$ROOT/scripts/prepare-android-tools.py"
elif [[ ! -x "$DEVICEHUB_ADB" ]] && ! command -v "$DEVICEHUB_ADB" >/dev/null 2>&1; then
    echo "error: DEVICEHUB_ADB must name an executable adb." >&2
    exit 1
fi
"$ASSET_PYTHON" "$ROOT/scripts/prepare-android-video.py"

xcodegen generate --quiet

SIGNING=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual)
# Build with the reusable ad-hoc Python cache, then sign the complete assembled bundle.
# This also covers Sparkle's nested helper applications, frameworks and XPC services.
[[ -z "${VERSION:-}" ]] || SIGNING+=(MARKETING_VERSION="$VERSION")
[[ -z "${BUILD_NUMBER:-}" ]] || SIGNING+=(CURRENT_PROJECT_VERSION="$BUILD_NUMBER")

mkdir -p "$DERIVED"
LOG=$DERIVED/build.log
echo "==> xcodebuild (log: $LOG)"
if ! xcodebuild -project phone-use.xcodeproj -scheme phone-use -configuration Release \
    -derivedDataPath "$DERIVED" -destination 'platform=macOS,arch=arm64' \
    -packageCachePath "$ROOT/.build/package-cache" \
    -clonedSourcePackagesDirPath "$ROOT/.build/SourcePackages" \
    "${SIGNING[@]}" build > "$LOG" 2>&1; then
    grep -E "error:|BUILD FAILED" "$LOG" | tail -20 >&2
    exit 1
fi
BUILT=$DERIVED/Build/Products/Release/phone-use.app

rm -rf "$APP"
mkdir -p "$ROOT/dist"
ditto "$BUILT" "$APP"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    "$ASSET_PYTHON" "$ROOT/scripts/sign-app.py" "$APP" "$SIGN_IDENTITY"
fi
codesign --verify --deep --strict "$APP"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    ZIP=$ROOT/dist/phone-use.zip
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    ditto -c -k --keepParent "$APP" "$ZIP"
fi

du -sh "$APP"
echo "Built $APP"
