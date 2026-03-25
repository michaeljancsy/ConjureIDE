#!/bin/bash
set -euo pipefail

# Downloads pre-built Monaco Editor for embedding in ConjureDSP's code editor.
# Run once before your first build:
#   ./scripts/setup-monaco.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MONACO_DIR="${REPO_ROOT}/ConjureDSPExtension/Resources/monaco/vs"
MONACO_VERSION="0.52.2"
TARBALL="monaco-editor-${MONACO_VERSION}.tgz"
URL="https://registry.npmjs.org/monaco-editor/-/monaco-editor-${MONACO_VERSION}.tgz"

if [ -d "${MONACO_DIR}" ]; then
    echo "Monaco Editor already exists at ${MONACO_DIR}"
    echo "Delete it first if you want to re-download: rm -rf ${MONACO_DIR}"
    exit 0
fi

echo "Downloading Monaco Editor v${MONACO_VERSION}..."
curl -L -o "/tmp/${TARBALL}" "${URL}"

echo "Extracting min/vs/ to ${MONACO_DIR}..."
mkdir -p "${MONACO_DIR}"
tar xzf "/tmp/${TARBALL}" -C "/tmp" "package/min/vs"
cp -R "/tmp/package/min/vs/"* "${MONACO_DIR}/"

# Extract and copy LICENSE separately (not included in partial extract)
tar xzf "/tmp/${TARBALL}" -C "/tmp" "package/LICENSE" 2>/dev/null || true
if [ -f "/tmp/package/LICENSE" ]; then
    cp "/tmp/package/LICENSE" "${REPO_ROOT}/ConjureDSPExtension/Resources/monaco/LICENSE"
fi

# Cleanup
rm -rf "/tmp/${TARBALL}" "/tmp/package"

echo "Monaco Editor v${MONACO_VERSION} installed to ${MONACO_DIR}"
echo "Bundle size: $(du -sh "${MONACO_DIR}" | cut -f1)"
