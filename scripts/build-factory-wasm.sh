#!/bin/bash
set -euo pipefail

# Pre-compiles every factory Rust preset (ConjureDSPExtension/Resources/preset_*_rust.rs)
# to a sidecar .wasm file in build/factory-wasm/<sha256>.wasm
#
# The filename is the SHA256 of the .rs source so the Swift-side loader can look
# up the sidecar by hashing the preset source at runtime. If the source is ever
# edited, the sidecar won't match and the loader falls through to the normal
# RustCompiler + WasmCache path.
#
# Sidecars live under build/ (already gitignored) rather than under Resources/,
# so they don't collide with Xcode's synchronized file group for the Resources
# folder. The Xcode "Build Factory WASM Sidecars" phase runs this script then
# explicitly rsyncs the output into the built bundle's Resources/factory-wasm/.
#
# This is the foundation of Phase 3 of the language-module split: once factory
# Rust presets play from sidecar .wasm files, the bundled rustc-dist/ becomes
# optional (needed only for *authoring* new Rust presets), and can be moved
# out of the app bundle and into a downloadable language module.
#
# Incremental: skips any preset whose sidecar is newer than both the source
# file and the conjuredsp rlib. Safe to run on every build.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RESOURCES="${REPO_ROOT}/ConjureDSPExtension/Resources"
SIDECAR_DIR="${REPO_ROOT}/build/factory-wasm"
RUSTC_DIR="${REPO_ROOT}/rustc-dist"
RUSTC="${RUSTC_DIR}/bin/rustc"
RLIB="${RUSTC_DIR}/lib/libconjuredsp.rlib"

if [ ! -x "${RUSTC}" ]; then
    echo "error: bundled rustc not found at ${RUSTC}" >&2
    echo "       Run scripts/setup-rustc.sh first." >&2
    exit 1
fi

# Rebuild the conjuredsp rlib if it's missing or older than any conjuredsp-rs
# source file. The "Copy Rust Compiler" Xcode phase does this too, but it writes
# into BUILT_PRODUCTS_DIR rather than the source tree, so the SRCROOT copy here
# can go stale. Rebuilding keeps factory-wasm sidecars pinned to the same rlib
# the Extension will actually run against.
CONJUREDSP_SRC="${REPO_ROOT}/rust/conjuredsp-rs/src/lib.rs"
needs_rlib_rebuild() {
    [ ! -f "${RLIB}" ] && return 0
    for f in "${REPO_ROOT}"/rust/conjuredsp-rs/src/*.rs; do
        [ "$f" -nt "${RLIB}" ] && return 0
    done
    return 1
}
if [ -f "${CONJUREDSP_SRC}" ] && needs_rlib_rebuild; then
    echo "factory-wasm: rebuilding conjuredsp rlib" >&2
    "${RUSTC}" \
        --target wasm32-wasip1 \
        --edition 2021 \
        --crate-type rlib \
        --crate-name conjuredsp \
        -C opt-level=2 \
        --sysroot "${RUSTC_DIR}" \
        -o "${RLIB}" \
        "${CONJUREDSP_SRC}"
fi

mkdir -p "${SIDECAR_DIR}"

# Shell helper: SHA256 of a file, lowercase hex, no filename.
sha256_of() {
    shasum -a 256 "$1" | awk '{print $1}'
}

# Returns 0 (success) if $1 is newer than $2, else 1. Missing $2 counts as "newer".
is_newer() {
    [ ! -e "$2" ] || [ "$1" -nt "$2" ]
}

COMPILED=0
SKIPPED=0
FAILED=0

shopt -s nullglob
for RS in "${RESOURCES}"/preset_*_rust.rs; do
    NAME="$(basename "${RS}" .rs)"
    SHA="$(sha256_of "${RS}")"
    WASM="${SIDECAR_DIR}/${SHA}.wasm"

    # Skip if sidecar exists and is newer than both source and rlib.
    if [ -f "${WASM}" ] \
       && ! is_newer "${RS}" "${WASM}" \
       && ! is_newer "${RLIB}" "${WASM}"; then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Compile to a temp file then rename so a partial .wasm never sticks around.
    TMP="${WASM}.tmp.$$"
    if "${RUSTC}" \
        --target wasm32-wasip1 \
        --edition 2021 \
        -C opt-level=2 \
        --crate-type cdylib \
        --sysroot "${RUSTC_DIR}" \
        --extern "conjuredsp=${RLIB}" \
        -o "${TMP}" \
        "${RS}" 2>"${TMP}.log"; then
        mv "${TMP}" "${WASM}"
        rm -f "${TMP}.log"
        COMPILED=$((COMPILED + 1))
    else
        echo "warning: failed to compile ${NAME}:" >&2
        sed 's/^/  /' "${TMP}.log" >&2
        rm -f "${TMP}" "${TMP}.log"
        FAILED=$((FAILED + 1))
    fi
done

# Prune orphan sidecars (their source file was renamed or deleted).
# Build a set of expected SHAs.
EXPECTED="$(mktemp)"
trap 'rm -f "${EXPECTED}"' EXIT
for RS in "${RESOURCES}"/preset_*_rust.rs; do
    sha256_of "${RS}" >> "${EXPECTED}"
done

PRUNED=0
for W in "${SIDECAR_DIR}"/*.wasm; do
    WSHA="$(basename "${W}" .wasm)"
    if ! grep -qx "${WSHA}" "${EXPECTED}"; then
        rm -f "${W}"
        PRUNED=$((PRUNED + 1))
    fi
done

echo "factory-wasm: compiled=${COMPILED} skipped=${SKIPPED} failed=${FAILED} pruned=${PRUNED}"

# Non-zero exit on any failure so CI/xcodebuild surface the problem.
if [ "${FAILED}" -gt 0 ]; then
    exit 1
fi
