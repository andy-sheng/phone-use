#!/bin/zsh
# Embeds automation's runtime into its app bundle: the PhoneUseKit daemon runtime (with
# MaaFramework installed into the same interpreter), the plugin runtime and the OCR resources.
#
#   embed-automation.sh <Automation.app> [codesign identity]
set -euo pipefail
ROOT=${0:A:h:h}
APP=${1:?usage: embed-automation.sh <app> [identity]}
IDENTITY=${2:-}
RESOURCES=$APP/Contents/Resources
CACHE=${DEVICEHUB_BUILD_CACHE:-$ROOT/.build/runtime-cache}

/bin/zsh "$ROOT/scripts/embed-daemon.sh" "$APP" "$IDENTITY" "$ROOT/Automation/requirements.txt"

mkdir -p "$RESOURCES/automation"
rsync -a --delete --delete-excluded --exclude __pycache__ \
    --include /devicehub_runtime/ --include '/devicehub_runtime/***' --exclude '*' \
    "$ROOT/Automation/" "$RESOURCES/automation/"
ASSETS_KEY=$(shasum -a 256 "$ROOT/Automation/assets.json" "$ROOT/Automation/prepare_assets.py" \
    "$ROOT/Automation/devicehub_runtime/images.py" | shasum -a 256 | cut -c1-16)
ASSETS="$CACHE/maa-core-$ASSETS_KEY"
"$RESOURCES/python/bin/python3" "$ROOT/Automation/prepare_assets.py" --output "$ASSETS" --cache "$ROOT/.build/maa-assets"
mkdir -p "$RESOURCES/maa-assets"
rsync -a --delete "$ASSETS/" "$RESOURCES/maa-assets/"
echo "Embedded automation runtime into ${APP:t}"
