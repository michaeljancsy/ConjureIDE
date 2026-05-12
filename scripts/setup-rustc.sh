#!/bin/bash
set -euo pipefail

# Downloads a standalone Rust compiler with wasm32-wasip1 target support for
# bundling inside the ConjureDSP AU extension. Run once before your first build:
#   ./scripts/setup-rustc.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RUSTC_DIR="${REPO_ROOT}/rustc-dist"
RUST_VERSION="1.95.0"
HOST_TARGET="aarch64-apple-darwin"

RUSTC_URL="https://static.rust-lang.org/dist/rustc-${RUST_VERSION}-${HOST_TARGET}.tar.xz"
CARGO_URL="https://static.rust-lang.org/dist/cargo-${RUST_VERSION}-${HOST_TARGET}.tar.xz"
STD_URL="https://static.rust-lang.org/dist/rust-std-${RUST_VERSION}-wasm32-wasip1.tar.xz"
HOST_STD_URL="https://static.rust-lang.org/dist/rust-std-${RUST_VERSION}-${HOST_TARGET}.tar.xz"

VERSION_FILE="${RUSTC_DIR}/VERSION.txt"
if [ -d "${RUSTC_DIR}" ]; then
    if [ -f "${VERSION_FILE}" ] && [ "$(cat "${VERSION_FILE}")" = "${RUST_VERSION}" ]; then
        echo "Rust compiler ${RUST_VERSION} already installed at ${RUSTC_DIR}"
        exit 0
    fi
    if [ -f "${VERSION_FILE}" ]; then
        INSTALLED="$(cat "${VERSION_FILE}")"
        echo "error: rustc-dist/ holds version ${INSTALLED}, but RUST_VERSION=${RUST_VERSION}" >&2
    else
        echo "error: rustc-dist/ exists but has no VERSION.txt; treat as stale" >&2
    fi
    echo "Delete it first to re-download: rm -rf ${RUSTC_DIR}" >&2
    exit 1
fi

TMPDIR=$(mktemp -d)
trap "rm -rf ${TMPDIR}" EXIT

echo "Downloading rustc ${RUST_VERSION} for ${HOST_TARGET}..."
curl -L --progress-bar -o "${TMPDIR}/rustc.tar.xz" "${RUSTC_URL}"

echo "Downloading cargo ${RUST_VERSION} for ${HOST_TARGET}..."
curl -L --progress-bar -o "${TMPDIR}/cargo.tar.xz" "${CARGO_URL}"

echo "Downloading wasm32-wasip1 standard library..."
curl -L --progress-bar -o "${TMPDIR}/rust-std-wasm.tar.xz" "${STD_URL}"

echo "Downloading ${HOST_TARGET} standard library (for build scripts)..."
curl -L --progress-bar -o "${TMPDIR}/rust-std-host.tar.xz" "${HOST_STD_URL}"

echo "Extracting rustc..."
tar xf "${TMPDIR}/rustc.tar.xz" -C "${TMPDIR}"

echo "Extracting cargo..."
tar xf "${TMPDIR}/cargo.tar.xz" -C "${TMPDIR}"

echo "Extracting wasm32-wasip1 std..."
tar xf "${TMPDIR}/rust-std-wasm.tar.xz" -C "${TMPDIR}"

echo "Extracting ${HOST_TARGET} std..."
tar xf "${TMPDIR}/rust-std-host.tar.xz" -C "${TMPDIR}"

# Assemble minimal sysroot — only what's needed for:
#   rustc --target wasm32-wasip1 --crate-type cdylib
mkdir -p "${RUSTC_DIR}/bin"
mkdir -p "${RUSTC_DIR}/lib/rustlib/${HOST_TARGET}/bin/gcc-ld"
mkdir -p "${RUSTC_DIR}/lib/rustlib/wasm32-wasip1"

RUSTC_EXTRACT="${TMPDIR}/rustc-${RUST_VERSION}-${HOST_TARGET}/rustc"
CARGO_EXTRACT="${TMPDIR}/cargo-${RUST_VERSION}-${HOST_TARGET}/cargo"
STD_EXTRACT="${TMPDIR}/rust-std-${RUST_VERSION}-wasm32-wasip1/rust-std-wasm32-wasip1"
HOST_STD_EXTRACT="${TMPDIR}/rust-std-${RUST_VERSION}-${HOST_TARGET}/rust-std-${HOST_TARGET}"

# rustc binary
cp "${RUSTC_EXTRACT}/bin/rustc" "${RUSTC_DIR}/bin/"

# cargo binary (used by companion app for crate package management)
cp "${CARGO_EXTRACT}/bin/cargo" "${RUSTC_DIR}/bin/"

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

# Host standard library (needed by cargo for compiling build scripts and proc macros)
cp -R "${HOST_STD_EXTRACT}/lib/rustlib/${HOST_TARGET}/lib" \
   "${RUSTC_DIR}/lib/rustlib/${HOST_TARGET}/"

# No-op rust-objcopy stub (rustc invokes this for split-debuginfo on macOS host builds;
# we don't need debug symbols for build scripts, so a no-op is fine)
printf '#!/bin/bash\nexit 0\n' > "${RUSTC_DIR}/lib/rustlib/${HOST_TARGET}/bin/rust-objcopy"
chmod +x "${RUSTC_DIR}/lib/rustlib/${HOST_TARGET}/bin/rust-objcopy"

# Compile conjuredsp library as rlib for wasm32-wasip1
CONJUREDSP_SRC="${REPO_ROOT}/rust/conjuredsp-rs/src/lib.rs"
CONJUREDSP_RLIB="${RUSTC_DIR}/lib/libconjuredsp.rlib"
if [ -f "${CONJUREDSP_SRC}" ]; then
    echo "Compiling conjuredsp library for wasm32-wasip1..."
    "${RUSTC_DIR}/bin/rustc" \
        --target wasm32-wasip1 \
        --edition 2024 \
        --crate-type rlib \
        --crate-name conjuredsp \
        -C opt-level=2 \
        --sysroot "${RUSTC_DIR}" \
        -o "${CONJUREDSP_RLIB}" \
        "${CONJUREDSP_SRC}"
    echo "conjuredsp rlib compiled: ${CONJUREDSP_RLIB}"
else
    echo "warning: conjuredsp-rs source not found at ${CONJUREDSP_SRC}, skipping rlib build"
fi

# Pin the installed version so future re-runs detect stale state.
echo "${RUST_VERSION}" > "${VERSION_FILE}"

echo ""
echo "Done! Minimal Rust compiler ${RUST_VERSION} installed at: ${RUSTC_DIR}"
echo "On-disk size: $(du -sh "${RUSTC_DIR}" | cut -f1)"
echo "You can now build the project with Xcode."
