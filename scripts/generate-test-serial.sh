#!/bin/bash
# Generates a test license serial for automated tests.
# Called as an Xcode Run Script build phase on BearBoneExtension.
#
# Looks for keypair.bin in the current repo; if in a worktree,
# falls back to the main worktree's copy. Writes the serial to
# $SRCROOT/.test-serial (gitignored). Tests read this file and
# skip gracefully if it's empty or missing.
#
# Always exits 0 — never fails the build.

set -uo pipefail

# Use SRCROOT if set (Xcode build phase), otherwise derive from script location
if [ -z "${SRCROOT:-}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    SRCROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

SERIAL_FILE="$SRCROOT/.test-serial"
KEYPAIR_PATH="$SRCROOT/tools/generate-license/keypair.bin"
TOOL_DIR=""

# Check local keypair first
if [ -f "$KEYPAIR_PATH" ]; then
    TOOL_DIR="$SRCROOT/tools/generate-license"
else
    # If in a worktree, try the main worktree
    MAIN_WORKTREE=$(cd "$SRCROOT" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's|/\.git$||')
    if [ -n "$MAIN_WORKTREE" ] && [ "$MAIN_WORKTREE" != "$SRCROOT" ]; then
        MAIN_KEYPAIR="$MAIN_WORKTREE/tools/generate-license/keypair.bin"
        if [ -f "$MAIN_KEYPAIR" ]; then
            TOOL_DIR="$MAIN_WORKTREE/tools/generate-license"
            echo "Using keypair from main worktree: $MAIN_WORKTREE"
        fi
    fi
fi

if [ -z "$TOOL_DIR" ]; then
    echo "⚠️ No keypair.bin found — skipping test serial generation"
    echo "   License tests will be skipped."
    rm -f "$SERIAL_FILE"
    exit 0
fi

# Ensure cargo is available
if ! command -v cargo &>/dev/null; then
    if [ -f "$HOME/.cargo/env" ]; then
        source "$HOME/.cargo/env"
    fi
fi

if ! command -v cargo &>/dev/null; then
    echo "⚠️ cargo not found — skipping test serial generation"
    rm -f "$SERIAL_FILE"
    exit 0
fi

# Generate the test serial
SERIAL=$(cd "$TOOL_DIR" && cargo run --quiet -- --email test@bearbone.dev 2>/dev/null)

if [ -z "$SERIAL" ]; then
    echo "⚠️ Failed to generate test serial"
    rm -f "$SERIAL_FILE"
    exit 0
fi

echo -n "$SERIAL" > "$SERIAL_FILE"
echo "✅ Test serial generated → .test-serial"
exit 0
