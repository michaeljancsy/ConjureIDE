#!/bin/bash
set -euo pipefail

# Downloads a standalone Rust compiler with wasm32-wasip1 target support for
# bundling inside the BearBone AU extension. Run once before your first build:
#   ./scripts/setup-rustc.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RUSTC_DIR="${REPO_ROOT}/rustc-dist"
RUST_VERSION="1.93.1"
HOST_TARGET="aarch64-apple-darwin"

RUSTC_URL="https://static.rust-lang.org/dist/rustc-${RUST_VERSION}-${HOST_TARGET}.tar.xz"
STD_URL="https://static.rust-lang.org/dist/rust-std-${RUST_VERSION}-wasm32-wasip1.tar.xz"

if [ -d "${RUSTC_DIR}" ]; then
    echo "Rust compiler already exists at ${RUSTC_DIR}"
    echo "Delete it first if you want to re-download: rm -rf ${RUSTC_DIR}"
    exit 0
fi

TMPDIR=$(mktemp -d)
trap "rm -rf ${TMPDIR}" EXIT

echo "Downloading rustc ${RUST_VERSION} for ${HOST_TARGET}..."
curl -L --progress-bar -o "${TMPDIR}/rustc.tar.xz" "${RUSTC_URL}"

echo "Downloading wasm32-wasip1 standard library..."
curl -L --progress-bar -o "${TMPDIR}/rust-std-wasm.tar.xz" "${STD_URL}"

echo "Extracting rustc..."
tar xf "${TMPDIR}/rustc.tar.xz" -C "${TMPDIR}"

echo "Extracting wasm32-wasip1 std..."
tar xf "${TMPDIR}/rust-std-wasm.tar.xz" -C "${TMPDIR}"

# Assemble minimal sysroot — only what's needed for:
#   rustc --target wasm32-wasip1 --crate-type cdylib
mkdir -p "${RUSTC_DIR}/bin"
mkdir -p "${RUSTC_DIR}/lib/rustlib/${HOST_TARGET}/bin/gcc-ld"
mkdir -p "${RUSTC_DIR}/lib/rustlib/wasm32-wasip1"

RUSTC_EXTRACT="${TMPDIR}/rustc-${RUST_VERSION}-${HOST_TARGET}/rustc"
STD_EXTRACT="${TMPDIR}/rust-std-${RUST_VERSION}-wasm32-wasip1/rust-std-wasm32-wasip1"

# rustc binary
cp "${RUSTC_EXTRACT}/bin/rustc" "${RUSTC_DIR}/bin/"

# librustc_driver dylib (loaded via @rpath from rustc)
# Skip sanitizer dylibs (librustc-stable_rt.*.dylib) — not needed
cp "${RUSTC_EXTRACT}/lib/librustc_driver"*.dylib "${RUSTC_DIR}/lib/"
# Also copy libstd and libLLVM if present (rustc may need them)
for lib in libstd libLLVM; do
    for f in "${RUSTC_EXTRACT}/lib/${lib}"*.dylib; do
        [ -f "$f" ] && cp "$f" "${RUSTC_DIR}/lib/"
    done
done

# WASM linker (rust-lld) and its gcc-ld frontend
cp "${RUSTC_EXTRACT}/lib/rustlib/${HOST_TARGET}/bin/rust-lld" \
   "${RUSTC_DIR}/lib/rustlib/${HOST_TARGET}/bin/"
cp "${RUSTC_EXTRACT}/lib/rustlib/${HOST_TARGET}/bin/gcc-ld/wasm-ld" \
   "${RUSTC_DIR}/lib/rustlib/${HOST_TARGET}/bin/gcc-ld/"

# wasm32-wasip1 standard library (rlibs + libc.a)
cp -R "${STD_EXTRACT}/lib/rustlib/wasm32-wasip1/lib" \
   "${RUSTC_DIR}/lib/rustlib/wasm32-wasip1/"

echo ""
echo "Done! Minimal Rust compiler ${RUST_VERSION} installed at: ${RUSTC_DIR}"
echo "On-disk size: $(du -sh "${RUSTC_DIR}" | cut -f1)"
echo "You can now build the project with Xcode."
