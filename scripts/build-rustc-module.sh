#!/bin/bash
# Build a rustc language-module tarball from the existing rustc-dist/.
#
# Output:
#   build/language-modules/rustc-<VERSION>-aarch64.tar.gz
#   build/language-modules/rustc-<VERSION>-aarch64.sha256
#
# The tarball expands to {bin/, lib/, ...} — exactly the layout
# RustCompiler.moduleSysroot() expects at
# <AppGroup>/LanguageModules/rustc/ after extraction by LanguageDownloader.
#
# Consumed by:
#   (future) scripts/publish-language-catalog.sh — uploads to R2, updates
#                                                   catalog.json
#   LanguageDownloader in ConjureDSPTerminal (SHA-verifies + extracts at
#                                             install time)
#
# The Developer ID re-signing step that the Xcode "Copy Rust Compiler" phase
# performs on the bundle copy is NOT done here — it needs to happen on the
# release machine with the signing identity in the keychain. The release
# pipeline should re-sign the extracted module after unpacking the tarball,
# then re-archive. For local/dev use the enforceCodesign flag on
# LanguageDownloader defaults to false, so unsigned test tarballs work.
#
# Usage: ./scripts/build-rustc-module.sh [VERSION]
#   VERSION defaults to the version reported by `rustc-dist/bin/rustc -V`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RUSTC_DIST="${REPO_ROOT}/rustc-dist"

if [ ! -d "${RUSTC_DIST}" ]; then
    echo "✗ ${RUSTC_DIST} missing — run scripts/setup-rustc.sh first" >&2
    exit 1
fi

# Default VERSION to whatever the bundled compiler reports. Matches the
# value setup-rustc.sh pinned at download time.
if [ -z "${1:-}" ]; then
    if [ -x "${RUSTC_DIST}/bin/rustc" ]; then
        VERSION="$(
            DYLD_LIBRARY_PATH="${RUSTC_DIST}/lib" \
                "${RUSTC_DIST}/bin/rustc" -V 2>/dev/null \
            | awk '{print $2}'
        )"
    fi
    VERSION="${VERSION:-1.93.1}"
else
    VERSION="$1"
fi

ARCH="aarch64"
OUTPUT_DIR="${REPO_ROOT}/build/language-modules"
TARBALL="${OUTPUT_DIR}/rustc-${VERSION}-${ARCH}.tar.gz"
SHA_FILE="${OUTPUT_DIR}/rustc-${VERSION}-${ARCH}.sha256"

# Sanity-check the expected layout. These are the exact paths RustCompiler
# relies on — if any are missing, the extracted module would be broken.
REQUIRED=(
    "bin/rustc"
    "bin/cargo"
    "lib/libconjuredsp.rlib"
    "lib/rustlib/${ARCH}-apple-darwin/bin/rust-lld"
    "lib/rustlib/wasm32-wasip1/lib"
)
for rel in "${REQUIRED[@]}"; do
    if [ ! -e "${RUSTC_DIST}/${rel}" ]; then
        echo "✗ Missing ${RUSTC_DIST}/${rel}" >&2
        echo "  Did you run scripts/setup-rustc.sh? If the rlib is" >&2
        echo "  missing, it'll be rebuilt by the next Xcode build or by" >&2
        echo "  scripts/build-factory-wasm.sh." >&2
        exit 1
    fi
done

# Ensure librustc_driver-*.dylib is present (name suffix is version-dependent).
if ! ls "${RUSTC_DIST}"/lib/librustc_driver-*.dylib >/dev/null 2>&1; then
    echo "✗ ${RUSTC_DIST}/lib/librustc_driver-*.dylib not found" >&2
    exit 1
fi

mkdir -p "${OUTPUT_DIR}"
rm -f "${TARBALL}" "${SHA_FILE}"

echo "→ Packing rustc ${VERSION} (${ARCH}) from ${RUSTC_DIST}"
# -C moves into the source dir so archive members start at bin/, lib/, etc.
# --exclude the in-tree timestamp files that the Xcode "Copy Rust Compiler"
# phase uses — they'd differ per-build and pollute the tarball.
COPYFILE_DISABLE=1 tar \
    --exclude '.DS_Store' \
    --exclude '.copy-stamp' \
    -czf "${TARBALL}" \
    -C "${RUSTC_DIST}" \
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
  "rustc": {
    "version": "${VERSION}",
    "sizeMB": ${SIZE_MB},
    "sha256": "${SHA}",
    "minApp": "1.0.15",
    "url": null,
    "licenseGate": null,
    "description": "Rust ${VERSION} compiler + wasm32-wasip1 sysroot + cargo"
  }
EOF
