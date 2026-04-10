#!/bin/bash
#
# build-and-release.sh — Build, notarize, and release in one step.
#
# Usage: ./scripts/build-and-release.sh [--skip-notarize] [--version X.Y.Z] [--build N] [--beta]
#
# This is a convenience wrapper that calls:
#   1. build.sh [--notarize] [--version ...] [--build ...] [--beta]
#   2. release.sh            (appcast, upload to R2)

set -euo pipefail

NOTARIZE=true
EXTRA_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-notarize) NOTARIZE=false; shift ;;
        --version)       EXTRA_ARGS+=("--version" "$2"); shift 2 ;;
        --build)         EXTRA_ARGS+=("--build" "$2"); shift 2 ;;
        --beta)          EXTRA_ARGS+=("--beta"); shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

BUILD_ARGS=()
$NOTARIZE && BUILD_ARGS+=("--notarize")
BUILD_ARGS+=("${EXTRA_ARGS[@]}")

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "========================================"
echo "  ConjureDSP Build & Release"
echo "========================================"
echo ""

"$SCRIPT_DIR/build.sh" "${BUILD_ARGS[@]}"
"$SCRIPT_DIR/release.sh"
