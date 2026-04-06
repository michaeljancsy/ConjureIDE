#!/bin/bash
set -euo pipefail

# Downloads a standalone free-threaded (no-GIL) Python 3.14 distribution for
# embedding in ConjureDSP. Run once before your first build:
#   cd rust && ./setup-python.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PYTHON_DIR="${SCRIPT_DIR}/python-dist"
PYTHON_VERSION="3.14.3"
RELEASE_TAG="20260211"
ARCHIVE="cpython-${PYTHON_VERSION}+${RELEASE_TAG}-aarch64-apple-darwin-freethreaded+pgo+lto-full.tar.zst"
URL="https://github.com/astral-sh/python-build-standalone/releases/download/${RELEASE_TAG}/${ARCHIVE}"

if [ -d "${PYTHON_DIR}" ]; then
    echo "Python distribution already exists at ${PYTHON_DIR}"
    echo "Delete it first if you want to re-download: rm -rf ${PYTHON_DIR}"
    exit 0
fi

# Ensure zstd is available (needed for .tar.zst archives)
if ! command -v zstd &>/dev/null; then
    echo "zstd not found — installing via Homebrew..."
    brew install zstd
fi

echo "Downloading free-threaded Python ${PYTHON_VERSION} (no-GIL)..."
curl -L -o "/tmp/${ARCHIVE}" "${URL}"

echo "Extracting to ${PYTHON_DIR}..."
# The full archive extracts as python/install/{bin,lib,...}
mkdir -p /tmp/python-extract
zstd -d "/tmp/${ARCHIVE}" --stdout | tar xf - -C /tmp/python-extract

# Move the install directory to our target location
mv /tmp/python-extract/python/install "${PYTHON_DIR}"

rm -rf /tmp/python-extract "/tmp/${ARCHIVE}"

echo "Installing numpy and scipy..."
"${PYTHON_DIR}/bin/python3" -m pip install --upgrade pip
"${PYTHON_DIR}/bin/python3" -m pip install numpy scipy

echo "Installing conjuredsp package..."
SITE_PACKAGES="$("${PYTHON_DIR}/bin/python3" -c 'import site; print(site.getsitepackages()[0])')"
rm -rf "${SITE_PACKAGES}/conjuredsp"
cp -r "${SCRIPT_DIR}/conjuredsp" "${SITE_PACKAGES}/conjuredsp"

echo ""
echo "Done! Free-threaded Python ${PYTHON_VERSION} (no-GIL) with numpy+scipy+conjuredsp installed at: ${PYTHON_DIR}"
echo "You can now build the project with Xcode."
