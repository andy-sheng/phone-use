#!/bin/zsh
# Bundle prepared, pinned platform-tools (or an explicit DEVICEHUB_ADB override), offline.
# Usage: embed-android-tools.sh <PhoneUse.app> [codesign identity]
set -euo pipefail
ROOT=${0:A:h:h}
APP=${1:?usage: embed-android-tools.sh <app> [identity]}
IDENTITY=${2:--}
ADB=${DEVICEHUB_ADB:-}
ASSET_PYTHON="$APP/Contents/Resources/python/bin/python3"
if [[ ! -x "$ASSET_PYTHON" ]]; then ASSET_PYTHON=${PYTHON:-python3}; fi
# Assets are prepared explicitly by setup-dev.sh. Release packaging only verifies/copies.
"$ASSET_PYTHON" "$ROOT/scripts/prepare-android-video.py" --bundle-dir "$APP/Contents/Resources/android"
DESTINATION="$APP/Contents/Resources/android/platform-tools"
if [[ -z "$ADB" ]]; then
    "$ASSET_PYTHON" "$ROOT/scripts/prepare-android-tools.py" --bundle-dir "$APP/Contents/Resources/android"
else
    # Preserve the explicit local-tool override for custom SDK installations.
    if [[ ! -x "$ADB" ]]; then ADB=$(command -v "$ADB" || true); fi
    if [[ ! -x "$ADB" ]]; then
        echo "error: DEVICEHUB_ADB must name an executable adb." >&2
        exit 1
    fi
    ADB=${ADB:A}
    SOURCE=${ADB:h}
    rm -rf "$DESTINATION"
    mkdir -p "$DESTINATION"
    cp "$ADB" "$DESTINATION/adb"
    for LICENSE in NOTICE.txt source.properties; do
        [[ ! -f "$SOURCE/$LICENSE" ]] || cp "$SOURCE/$LICENSE" "$DESTINATION/$LICENSE"
    done
    if [[ -d "$SOURCE/lib64" ]]; then
        rsync -a --delete "$SOURCE/lib64/" "$DESTINATION/lib64/"
    fi
fi
if [[ -d "$DESTINATION/lib64" ]]; then
    for LIBRARY in "$DESTINATION"/lib64/*.dylib(N); do
        codesign --force --sign "$IDENTITY" --options runtime "$LIBRARY"
    done
fi
codesign --force --sign "$IDENTITY" --options runtime "$DESTINATION/adb"
echo "Embedded Android platform-tools"
