#!/bin/zsh
# Creates the Python environment the daemon runs from during development (.venv-daemon).
set -euo pipefail
cd "$(dirname "$0")/.."

PYTHON=${PYTHON:-python3}
if [[ ! -x .venv-daemon/bin/python ]]; then
    "$PYTHON" -m venv .venv-daemon
fi
mkdir -p .build/pip-cache
.venv-daemon/bin/python -m pip install --cache-dir .build/pip-cache --quiet -r Daemon/requirements.txt
.venv-daemon/bin/python scripts/prepare-android-tools.py --download
.venv-daemon/bin/python scripts/prepare-android-video.py --download
echo "daemon environment ready: $(.venv-daemon/bin/python -c 'import pymobiledevice3, sys; print(sys.version.split()[0])')"
