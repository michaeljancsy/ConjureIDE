#!/bin/bash
set -euo pipefail

# Downloads xterm.js for embedding a terminal in ConjureDSP's AU extension.
# Run once before your first build:
#   ./scripts/setup-xterm.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TERMINAL_DIR="${REPO_ROOT}/ConjureDSPExtension/Resources/terminal"
XTERM_VERSION="5.3.0"
ADDON_FIT_VERSION="0.11.0"
ADDON_WEBLINKS_VERSION="0.12.0"

if [ -f "${TERMINAL_DIR}/xterm.js" ] && [ "$(wc -c < "${TERMINAL_DIR}/xterm.js")" -gt 1000 ]; then
    echo "xterm.js already exists at ${TERMINAL_DIR}"
    echo "Delete it first if you want to re-download: rm -f ${TERMINAL_DIR}/xterm.js ${TERMINAL_DIR}/xterm.css"
    exit 0
fi

mkdir -p "${TERMINAL_DIR}"

echo "Downloading xterm.js v${XTERM_VERSION}..."

# Download xterm core
curl -sfL "https://cdn.jsdelivr.net/npm/xterm@${XTERM_VERSION}/lib/xterm.min.js" -o "${TERMINAL_DIR}/xterm.js"
curl -sfL "https://cdn.jsdelivr.net/npm/xterm@${XTERM_VERSION}/css/xterm.min.css" -o "${TERMINAL_DIR}/xterm.css"

# Download addons
curl -sfL "https://cdn.jsdelivr.net/npm/@xterm/addon-fit@${ADDON_FIT_VERSION}/lib/addon-fit.min.js" -o "${TERMINAL_DIR}/addon-fit.js"
curl -sfL "https://cdn.jsdelivr.net/npm/@xterm/addon-web-links@${ADDON_WEBLINKS_VERSION}/lib/addon-web-links.min.js" -o "${TERMINAL_DIR}/addon-web-links.js"

# Verify downloads (xterm.js should be >100KB)
if [ "$(wc -c < "${TERMINAL_DIR}/xterm.js")" -lt 1000 ]; then
    echo "error: xterm.js download appears corrupt (too small)" >&2
    rm -f "${TERMINAL_DIR}/xterm.js" "${TERMINAL_DIR}/xterm.css" "${TERMINAL_DIR}/addon-fit.js" "${TERMINAL_DIR}/addon-web-links.js"
    exit 1
fi

echo "xterm.js v${XTERM_VERSION} installed to ${TERMINAL_DIR}"
echo "Files:"
ls -la "${TERMINAL_DIR}/xterm.js" "${TERMINAL_DIR}/xterm.css" "${TERMINAL_DIR}/addon-fit.js" "${TERMINAL_DIR}/addon-web-links.js"
echo "Total size: $(du -sh "${TERMINAL_DIR}" | cut -f1)"
