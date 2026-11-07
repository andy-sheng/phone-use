#!/bin/zsh
# Copies a self-contained Python runtime with the daemon into an app bundle.
#
#   embed-daemon.sh <phone-use.app> [codesign identity]
#
# The runtime (python-build-standalone + Daemon/requirements.txt) is staged and signed once per
# Python build, requirements and identity in $DEVICEHUB_BUILD_CACHE, so repeated builds only
# sync files. PYTHON_URL overrides the default latest Python 3.13 build.
set -euo pipefail
ROOT=${0:A:h:h}
APP=${1:?usage: embed-daemon.sh <app> [identity]}
IDENTITY=${2:-}
RESOURCES=$APP/Contents/Resources
CACHE=${DEVICEHUB_BUILD_CACHE:-$ROOT/.build/runtime-cache}
mkdir -p "$CACHE" "$RESOURCES"

# The first resolved build is pinned in the cache so later builds stay reproducible; delete
# $CACHE/python-url to move to a newer one. Resolved without the GitHub API, which
# rate-limits anonymous callers.
EXPECTED_SHA=""
PINNED=$CACHE/python-url
if [[ -z "${PYTHON_URL:-}" && -f "$PINNED" ]]; then
    read -r EXPECTED_SHA PYTHON_URL < "$PINNED"
fi
if [[ -z "${PYTHON_URL:-}" ]]; then
    RELEASES=https://github.com/astral-sh/python-build-standalone/releases
    TAG=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$RELEASES/latest")
    TAG=${TAG:t}
    LINE=$(curl -fsSL "$RELEASES/download/$TAG/SHA256SUMS" |
        grep -E ' cpython-3\.13\.[0-9]+\+[0-9]+-aarch64-apple-darwin-install_only_stripped\.tar\.gz$' | head -1)
    [[ -n "$LINE" ]] || { echo "error: no Python 3.13 build in release $TAG" >&2; exit 1; }
    EXPECTED_SHA=${LINE%% *}
    PYTHON_URL=$RELEASES/download/$TAG/${LINE##* }
    print -r -- "$EXPECTED_SHA $PYTHON_URL" > "$PINNED"
fi
TARBALL=$CACHE/${PYTHON_URL:t}
if [[ ! -f "$TARBALL" ]]; then
    echo "Downloading ${TARBALL:t}"
    curl -fL --retry 3 -o "$TARBALL.part" "$PYTHON_URL"
    mv "$TARBALL.part" "$TARBALL"
fi
if [[ -n "$EXPECTED_SHA" ]] && [[ "$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)" != "$EXPECTED_SHA" ]]; then
    rm -f "$TARBALL" "$CACHE/python-url"
    echo "error: checksum mismatch for ${TARBALL:t}" >&2
    exit 1
fi

KEY=$(print -r -- "${TARBALL:t} $(shasum -a 256 "$ROOT/Daemon/requirements.txt" "$ROOT/Automation/requirements.txt") $IDENTITY" | shasum -a 256 | cut -c1-16)
STAGE=$CACHE/runtime-$KEY
if [[ ! -x "$STAGE/python/bin/python3" ]]; then
    echo "Staging Python runtime ($KEY)"
    rm -rf "$STAGE.tmp"
    mkdir -p "$STAGE.tmp"
    tar -xzf "$TARBALL" -C "$STAGE.tmp"
    "$STAGE.tmp/python/bin/python3" -m pip install --quiet --no-compile --no-cache-dir \
        --disable-pip-version-check -r "$ROOT/Daemon/requirements.txt" -r "$ROOT/Automation/requirements.txt"
    find "$STAGE.tmp" -name __pycache__ -type d -prune -exec rm -rf {} +
    find "$STAGE.tmp/python/lib" -path "*/site-packages/*" -type d -name tests -prune -exec rm -rf {} +
    if [[ -n "$IDENTITY" ]]; then
        SIGN=(codesign --force --sign "$IDENTITY")
        [[ "$IDENTITY" != "-" ]] && SIGN+=(--options runtime --timestamp)
        find "$STAGE.tmp/python" -type f \( -name "*.so" -o -name "*.dylib" \) -print0 | xargs -0 -n 50 "${SIGN[@]}" 2>/dev/null
        for interpreter in "$STAGE.tmp/python/bin/"python3*(.); do
            if file -b "$interpreter" | grep -q Mach-O; then
                "${SIGN[@]}" --entitlements "$ROOT/Support/Python.entitlements" "$interpreter" 2>/dev/null
            fi
        done
    fi
    rm -rf "$STAGE"
    mv "$STAGE.tmp" "$STAGE"
fi

rsync -a --delete "$STAGE/python/" "$RESOURCES/python/"
mkdir -p "$RESOURCES/daemon"
rsync -a --delete --exclude __pycache__ "$ROOT/Daemon/devicehubd/" "$RESOURCES/daemon/devicehubd/"
mkdir -p "$RESOURCES/automation"
rsync -a --delete --delete-excluded --exclude __pycache__ \
    --include /devicehub_runtime/ --include '/devicehub_runtime/***' --exclude '*' \
    "$ROOT/Automation/" "$RESOURCES/automation/"
ASSETS_KEY=$(shasum -a 256 "$ROOT/Automation/assets.json" "$ROOT/Automation/prepare_assets.py" \
    "$ROOT/Automation/devicehub_runtime/images.py" | shasum -a 256 | cut -c1-16)
ASSETS="$CACHE/maa-core-$ASSETS_KEY"
"$STAGE/python/bin/python3" "$ROOT/Automation/prepare_assets.py" --output "$ASSETS" --cache "$ROOT/.build/maa-assets"
mkdir -p "$RESOURCES/maa-assets"
rsync -a --delete "$ASSETS/" "$RESOURCES/maa-assets/"
/bin/zsh "$ROOT/scripts/embed-android-tools.sh" "$APP" "${IDENTITY:--}"
echo "Embedded daemon runtime into ${APP:t}"
