#!/bin/bash
# Build a Python language-module tarball from the existing rust/python-dist.
#
# Output:
#   build/language-modules/python-<VERSION>-aarch64.tar.gz
#   build/language-modules/python-<VERSION>-aarch64.sha256
#
# The tarball expands to {bin/, lib/, ...} — exactly the layout the
# Terminal app's resolvePythonSource() expects when LanguageModules/python/
# is the source.
#
# Consumed by:
#   scripts/publish-language-catalog.sh (TODO, phase 2+)
#   LanguageDownloader in ConjureDSPTerminal (extracts at install time)
#
# Usage: ./scripts/build-python-module.sh [VERSION]
#   VERSION defaults to "3.14.3" but the real version should match the
#   python-build-standalone tag in rust/setup-python.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PYTHON_DIST="${REPO_ROOT}/rust/python-dist"

VERSION="${1:-3.14.3}"
ARCH="aarch64"
OUTPUT_DIR="${REPO_ROOT}/build/language-modules"
TARBALL="${OUTPUT_DIR}/python-${VERSION}-${ARCH}.tar.gz"
SHA_FILE="${OUTPUT_DIR}/python-${VERSION}-${ARCH}.sha256"

if [ ! -d "${PYTHON_DIST}" ]; then
    echo "✗ ${PYTHON_DIST} missing — run rust/setup-python.sh first" >&2
    exit 1
fi

# Sanity-check the expected layout.
for rel in bin/python3 lib/libpython3.14t.dylib lib/python3.14t; do
    if [ ! -e "${PYTHON_DIST}/${rel}" ]; then
        echo "✗ Missing ${PYTHON_DIST}/${rel}" >&2
        exit 1
    fi
done

mkdir -p "${OUTPUT_DIR}"
rm -f "${TARBALL}" "${SHA_FILE}"

echo "→ Packing Python ${VERSION} (${ARCH}) from ${PYTHON_DIST}"
# -C moves into the source dir so archive members start at bin/, lib/, etc.
# --disable-copyfile avoids macOS ._ files ending up in the archive.
COPYFILE_DISABLE=1 tar \
    --disable-copyfile \
    --exclude '.DS_Store' \
    --exclude '__pycache__' \
    --exclude '*.pyc' \
    -czf "${TARBALL}" \
    -C "${PYTHON_DIST}" \
    bin lib share 2>/dev/null || \
COPYFILE_DISABLE=1 tar \
    --exclude '.DS_Store' \
    --exclude '__pycache__' \
    --exclude '*.pyc' \
    -czf "${TARBALL}" \
    -C "${PYTHON_DIST}" \
    bin lib

SIZE_MB=$(du -m "${TARBALL}" | cut -f1)
SHA=$(shasum -a 256 "${TARBALL}" | awk '{print $1}')
printf '%s\n' "${SHA}" > "${SHA_FILE}"

echo "✓ ${TARBALL}"
echo "  size: ${SIZE_MB} MB"
echo "  sha256: ${SHA}"
echo ""
echo "Catalog entry:"
cat <<EOF
  "python": {
    "version": "${VERSION}",
    "sizeMB": ${SIZE_MB},
    "sha256": "${SHA}",
    "minApp": "1.0.15",
    "url": null,
    "licenseGate": null,
    "description": "Free-threaded Python ${VERSION} + numpy + scipy"
  }
EOF
