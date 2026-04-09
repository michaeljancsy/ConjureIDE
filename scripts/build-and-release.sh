#!/bin/bash
#
# build-and-release.sh — Build, notarize, and release in one step.
#
# Usage: ./scripts/build-and-release.sh [--skip-notarize] [--version X.Y.Z] [--build N]
#
# This is a convenience wrapper that calls:
#   1. build.sh [--notarize] [--version ...] [--build ...]
#   2. release.sh            (appcast, upload to R2)

set -euo pipefail

BUILD_ARGS=("--notarize")
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-notarize) BUILD_ARGS=(); shift ;;
        --version)       BUILD_ARGS+=("--version" "$2"); shift 2 ;;
        --build)         BUILD_ARGS+=("--build" "$2"); shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "========================================"
echo "  ConjureDSP Build & Release"
echo "========================================"
echo ""

"$SCRIPT_DIR/build.sh" "${BUILD_ARGS[@]}"
"$SCRIPT_DIR/release.sh"
