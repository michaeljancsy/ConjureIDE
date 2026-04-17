#!/bin/bash
# Release size guard — fails if the signed .app exceeds a budget.
#
# Usage:
#   ./scripts/check-release-size.sh <path-to-.app> [max_mb]
#
# If max_mb is omitted, CD_MAX_APP_MB (env) is used, else the default below.
# Override with: CD_MAX_APP_MB=600 ./scripts/check-release-size.sh path/to/App.app
#
# The budget should ratchet down as bundled runtimes are stripped and moved
# to on-demand language modules:
#
#   Baseline now (rustc stripped, Python still bundled):  ~800 MB
#   After Python strip + strip-on-install:                ~300 MB
#   Plan target (fully modular, base only):               150 MB
#
# The default below is intentionally set just above the current measured size
# so any accidental reintroduction of a bundled runtime trips the guard.

set -euo pipefail

DEFAULT_MAX_MB=850

if [ $# -lt 1 ]; then
    echo "usage: $0 <path-to-.app> [max_mb]" >&2
    exit 2
fi

APP_PATH="$1"
MAX_MB="${2:-${CD_MAX_APP_MB:-${DEFAULT_MAX_MB}}}"

if [ ! -d "${APP_PATH}" ]; then
    echo "✗ ${APP_PATH} is not a directory" >&2
    exit 2
fi

SIZE_MB=$(du -m -d 0 "${APP_PATH}" | awk '{print $1}')

echo "=== Release size check ==="
echo "App:      ${APP_PATH}"
echo "Size:     ${SIZE_MB} MB"
echo "Budget:   ${MAX_MB} MB"

if [ "${SIZE_MB}" -gt "${MAX_MB}" ]; then
    echo "✗ FAIL: size ${SIZE_MB} MB exceeds budget ${MAX_MB} MB" >&2
    echo "" >&2
    echo "Top-level bundle breakdown (largest first):" >&2
    du -m -d 2 "${APP_PATH}"/Contents 2>/dev/null | sort -rn | head -15 >&2
    exit 1
fi

echo "✓ PASS"
