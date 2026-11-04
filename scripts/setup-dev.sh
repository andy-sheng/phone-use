#!/bin/zsh
# Creates the Python environment the daemon runs from during development (.venv-daemon).
set -euo pipefail
cd "$(dirname "$0")/.."

PYTHON=${PYTHON:-python3}
if [[ ! -x .venv-daemon/bin/python ]]; then
    "$PYTHON" -m venv .venv-daemon
fi
.venv-daemon/bin/python -m pip install --quiet --upgrade pip
.venv-daemon/bin/python -m pip install --quiet -r Daemon/requirements.txt
echo "daemon environment ready: $(.venv-daemon/bin/python -c 'import pymobiledevice3, sys; print(sys.version.split()[0])')"
