#!/bin/bash
set -euo pipefail

# Downloads the uv Python package manager binary for bundling inside the
# ConjureDSPTerminal companion app. Run once before your first build:
#   ./scripts/setup-uv.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
UV_DIR="${REPO_ROOT}/uv-dist"
UV_VERSION="0.6.12"
HOST_TARGET="aarch64-apple-darwin"

UV_URL="https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${HOST_TARGET}.tar.gz"

if [ -d "${UV_DIR}" ]; then
    echo "uv already exists at ${UV_DIR}"
    echo "Delete it first if you want to re-download: rm -rf ${UV_DIR}"
    exit 0
fi

TMPDIR=$(mktemp -d)
trap "rm -rf ${TMPDIR}" EXIT

echo "Downloading uv ${UV_VERSION} for ${HOST_TARGET}..."
curl -L --progress-bar -o "${TMPDIR}/uv.tar.gz" "${UV_URL}"

echo "Extracting..."
tar xzf "${TMPDIR}/uv.tar.gz" -C "${TMPDIR}"

mkdir -p "${UV_DIR}"
cp "${TMPDIR}/uv-${HOST_TARGET}/uv" "${UV_DIR}/uv"
chmod +x "${UV_DIR}/uv"

echo ""
echo "Done! uv ${UV_VERSION} installed at: ${UV_DIR}/uv"
echo "On-disk size: $(du -sh "${UV_DIR}" | cut -f1)"
echo "Version: $("${UV_DIR}/uv" --version)"
