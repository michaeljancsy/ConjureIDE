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

if [ -f "${PYTHON_DIR}/.setup-complete" ]; then
    echo "Python distribution already exists at ${PYTHON_DIR}"
    echo "Delete it first if you want to re-download: rm -rf ${PYTHON_DIR}"
    exit 0
fi

# Clean up any incomplete previous run
if [ -d "${PYTHON_DIR}" ]; then
    echo "Found incomplete Python distribution — removing and starting fresh..."
    rm -rf "${PYTHON_DIR}"
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

"${PYTHON_DIR}/bin/python3" -m pip install --upgrade pip

echo "Installing numpy/scipy build tools..."
"${PYTHON_DIR}/bin/python3" -m pip install meson-python meson ninja cython

echo "Building numpy against Accelerate..."
"${PYTHON_DIR}/bin/python3" -m pip install numpy --no-binary=numpy \
  -Csetup-args=-Dblas=accelerate \
  -Csetup-args=-Dlapack=accelerate

echo "Building scipy against Accelerate..."
if command -v gfortran &>/dev/null; then
    "${PYTHON_DIR}/bin/python3" -m pip install scipy --no-binary=scipy \
      -Csetup-args=-Dblas=accelerate \
      -Csetup-args=-Dlapack=accelerate
else
    echo "gfortran not found — installing scipy from pre-built wheel (uses OpenBLAS)"
    echo "Install gfortran via Homebrew (brew install gcc) and re-run setup-python.sh to get Accelerate-linked scipy."
    "${PYTHON_DIR}/bin/python3" -m pip install scipy
fi

echo "Installing conjuredsp package..."
SITE_PACKAGES="$(${PYTHON_DIR}/bin/python3 -c 'import site; print(site.getsitepackages()[0])')"
rm -rf "${SITE_PACKAGES}/conjuredsp"
cp -r "${SCRIPT_DIR}/conjuredsp" "${SITE_PACKAGES}/conjuredsp"

# Mark setup as complete so the guard clause knows this isn't a partial install
touch "${PYTHON_DIR}/.setup-complete"

echo ""
echo "Done! Free-threaded Python ${PYTHON_VERSION} (no-GIL) with numpy+scipy (Accelerate-linked)+conjuredsp installed at: ${PYTHON_DIR}"
echo "You can now build the project with Xcode."
