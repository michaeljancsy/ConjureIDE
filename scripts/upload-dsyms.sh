#!/bin/bash
set -euo pipefail

# Upload dSYM files to Sentry for crash report symbolication.
# Runs as a post-build phase on the host app target.
# Skipped during test actions and when sentry-cli is not installed.
#
# Auth token is read from ${SRCROOT}/.sentryclirc (gitignored).

if [ "${ACTION:-build}" = "test" ] || [ "${ACTION:-build}" = "build-for-testing" ]; then
    echo "Skipping dSYM upload during test action" >&2
    exit 0
fi

# Homebrew on Apple Silicon
export PATH="/opt/homebrew/bin:${PATH}"

if ! command -v sentry-cli &>/dev/null; then
    echo "warning: sentry-cli not found, skipping dSYM upload. Install with: brew install getsentry/tools/sentry-cli" >&2
    exit 0
fi

# Read auth token from project-level .sentryclirc
SENTRYCLIRC="${SRCROOT}/.sentryclirc"
if [ ! -f "${SENTRYCLIRC}" ]; then
    echo "warning: ${SENTRYCLIRC} not found, skipping dSYM upload" >&2
    exit 0
fi

export SENTRY_PROPERTIES="${SENTRYCLIRC}"

DSYM_DIR="${DWARF_DSYM_FOLDER_PATH}"
if [ -z "${DSYM_DIR:-}" ]; then
    echo "warning: DWARF_DSYM_FOLDER_PATH not set, skipping dSYM upload" >&2
    exit 0
fi

echo "Uploading dSYMs from ${DSYM_DIR}..." >&2
sentry-cli debug-files upload --include-sources "${DSYM_DIR}" 2>&1 | head -20 >&2
echo "dSYM upload complete" >&2
