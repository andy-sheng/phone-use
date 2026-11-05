#!/bin/zsh
# Builds dist/DeviceHub.app from the Xcode project (generated from project.yml): the app, its
# MCP server and CLI in Contents/Helpers, and the embedded Python daemon runtime.
# Building needs Xcode; running the result does not.
#
#   SIGN_IDENTITY   e.g. "Developer ID Application: Example (TEAMID)"; ad-hoc by default
#   TEAM_ID         development team for SIGN_IDENTITY
#   NOTARY_PROFILE  notarytool keychain profile; when set the app is notarized and stapled
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
DERIVED=${DERIVED_DATA:-$ROOT/.build/xcode}
APP=$ROOT/dist/DeviceHub.app

xcodegen generate --quiet

SIGNING=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual)
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    SIGNING=(CODE_SIGN_IDENTITY="$SIGN_IDENTITY" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="${TEAM_ID:-}"
             OTHER_CODE_SIGN_FLAGS=--timestamp)
fi

mkdir -p "$DERIVED"
LOG=$DERIVED/build.log
echo "==> xcodebuild (log: $LOG)"
if ! xcodebuild -project DeviceHub.xcodeproj -scheme DeviceHub -configuration Release \
    -derivedDataPath "$DERIVED" -destination 'platform=macOS,arch=arm64' \
    -packageCachePath "$ROOT/.build/package-cache" \
    -clonedSourcePackagesDirPath "$ROOT/.build/SourcePackages" \
    "${SIGNING[@]}" build > "$LOG" 2>&1; then
    grep -E "error:|BUILD FAILED" "$LOG" | tail -20 >&2
    exit 1
fi
BUILT=$DERIVED/Build/Products/Release/DeviceHub.app

rm -rf "$APP"
mkdir -p "$ROOT/dist"
ditto "$BUILT" "$APP"
codesign --verify --deep --strict "$APP"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    ZIP=$ROOT/dist/DeviceHub.zip
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    ditto -c -k --keepParent "$APP" "$ZIP"
fi

du -sh "$APP"
echo "Built $APP"
