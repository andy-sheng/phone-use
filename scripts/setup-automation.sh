#!/bin/zsh
# Prepare the host MaaFramework runtime and shared OCR model.
set -euo pipefail
cd "$(dirname "$0")/.."

MAA_PYTHON=${MAA_PYTHON:-python3.13}
if [[ ! -x .venv-maa/bin/python ]]; then
    "$MAA_PYTHON" -m venv .venv-maa
fi
.venv-maa/bin/python -m pip install --cache-dir .build/pip-cache -r Automation/requirements.txt
.venv-maa/bin/python Automation/prepare_assets.py --output .build/maa-core --cache .build/maa-assets
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-module-cache" \
swift build --product phone-use --cache-path .build/swift-cache \
    --config-path .build/swift-config --security-path .build/swift-security
echo "Automation runtime ready. Open phone-use and install a plugin to add tasks."
