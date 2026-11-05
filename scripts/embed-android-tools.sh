#!/bin/zsh
# Bundle the build machine's Android platform-tools; no network download is required.
# Usage: embed-android-tools.sh <phone-use.app> [codesign identity]
set -euo pipefail
ROOT=${0:A:h:h}
APP=${1:?usage: embed-android-tools.sh <app> [identity]}
IDENTITY=${2:--}
ADB=${DEVICEHUB_ADB:-}
if [[ -z "$ADB" ]]; then
    for CANDIDATE in "${ANDROID_HOME:-}/platform-tools/adb" \
                     "${ANDROID_SDK_ROOT:-}/platform-tools/adb" \
                     "$HOME/Library/Android/sdk/platform-tools/adb" \
                     /opt/homebrew/bin/adb /usr/local/bin/adb; do
        if [[ -x "$CANDIDATE" ]]; then ADB=$CANDIDATE; break; fi
    done
fi
if [[ -z "$ADB" ]]; then ADB=$(command -v adb || true); fi
if [[ ! -x "$ADB" ]]; then
    echo "error: Android platform-tools are required for release builds; set DEVICEHUB_ADB to adb." >&2
    exit 1
fi
ADB=${ADB:A}
SOURCE=${ADB:h}
ASSET_PYTHON="$APP/Contents/Resources/python/bin/python3"
if [[ ! -x "$ASSET_PYTHON" ]]; then ASSET_PYTHON=${PYTHON:-python3}; fi
# Assets are prepared explicitly by setup-dev.sh. Release packaging only verifies/copies.
"$ASSET_PYTHON" "$ROOT/scripts/prepare-android-video.py" --bundle-dir "$APP/Contents/Resources/android"
DESTINATION="$APP/Contents/Resources/android/platform-tools"
mkdir -p "$DESTINATION"
cp "$ADB" "$DESTINATION/adb"
for LICENSE in NOTICE.txt source.properties; do
    [[ ! -f "$SOURCE/$LICENSE" ]] || cp "$SOURCE/$LICENSE" "$DESTINATION/$LICENSE"
done
if [[ -d "$SOURCE/lib64" ]]; then
    rsync -a --delete "$SOURCE/lib64/" "$DESTINATION/lib64/"
    for LIBRARY in "$DESTINATION"/lib64/*.dylib(N); do
        codesign --force --sign "$IDENTITY" --options runtime "$LIBRARY"
    done
fi
codesign --force --sign "$IDENTITY" --options runtime "$DESTINATION/adb"
echo "Embedded Android platform-tools"
