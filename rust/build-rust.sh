#!/bin/bash
set -euo pipefail

RUST_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST_PATH="${RUST_DIR}/conjure_dsp/Cargo.toml"

# Source cargo environment
if [ -f "$HOME/.cargo/env" ]; then
    . "$HOME/.cargo/env"
fi

# Use the bundled Python distribution for pyo3
PYTHON_DIST="${RUST_DIR}/python-dist"
if [ ! -d "${PYTHON_DIST}" ]; then
    # In a git worktree, symlink python-dist from the main worktree
    MAIN_WORKTREE=$(git -C "${RUST_DIR}" worktree list --porcelain 2>/dev/null | head -1 | sed 's/worktree //')
    if [ -n "${MAIN_WORKTREE}" ] && [ -d "${MAIN_WORKTREE}/rust/python-dist" ]; then
        echo "note: Symlinking python-dist from main worktree" >&2
        ln -s "${MAIN_WORKTREE}/rust/python-dist" "${PYTHON_DIST}"
    fi
fi
if [ -d "${PYTHON_DIST}" ]; then
    export PYO3_PYTHON="${PYTHON_DIST}/bin/python3"
else
    echo "warning: Bundled Python not found at ${PYTHON_DIST}. Run rust/setup-python.sh first." >&2
    echo "warning: Falling back to system python3." >&2
    export PYO3_PYTHON="python3"
fi

# Map a single Xcode arch to a Rust target triple
arch_to_rust_target() {
    local arch="$1"
    local platform="${PLATFORM_NAME:-macosx}"
    case "${platform}" in
        macosx)
            case "${arch}" in
                arm64)  echo "aarch64-apple-darwin" ;;
                x86_64) echo "x86_64-apple-darwin" ;;
                *)      echo "error: Unsupported arch: ${arch}" >&2; exit 1 ;;
            esac
            ;;
        iphoneos)
            echo "aarch64-apple-ios"
            ;;
        iphonesimulator)
            case "${arch}" in
                arm64)  echo "aarch64-apple-ios-sim" ;;
                x86_64) echo "x86_64-apple-ios" ;;
                *)      echo "error: Unsupported arch: ${arch}" >&2; exit 1 ;;
            esac
            ;;
        *)
            echo "error: Unsupported platform: ${platform}" >&2; exit 1
            ;;
    esac
}

# Build mode
if [ "${CONFIGURATION:-Debug}" = "Release" ]; then
    CARGO_FLAGS="--release"
    RUST_BUILD_DIR="release"
else
    CARGO_FLAGS=""
    RUST_BUILD_DIR="debug"
fi

LIB_DST="${BUILT_PRODUCTS_DIR:-${RUST_DIR}/target}/libconjure_dsp.a"

# Build for each architecture
LIBS=()
for ARCH in ${ARCHS:-arm64}; do
    RUST_TARGET=$(arch_to_rust_target "${ARCH}")
    cargo build --manifest-path "${MANIFEST_PATH}" --target "${RUST_TARGET}" ${CARGO_FLAGS}
    LIBS+=("${RUST_DIR}/target/${RUST_TARGET}/${RUST_BUILD_DIR}/libconjure_dsp.a")
done

# Combine with lipo if multiple architectures, otherwise just copy
if [ ${#LIBS[@]} -gt 1 ]; then
    lipo -create "${LIBS[@]}" -output "${LIB_DST}"
else
    cp "${LIBS[0]}" "${LIB_DST}"
fi

# Regenerate C header (only overwrite if changed, to avoid triggering Swift recompilation)
HEADER="${RUST_DIR}/include/conjure_dsp.h"
HEADER_TMP="${HEADER}.tmp"
cbindgen --config "${RUST_DIR}/cbindgen.toml" \
         --crate conjure_dsp \
         --output "${HEADER_TMP}" \
         "${RUST_DIR}/conjure_dsp"
if ! cmp -s "${HEADER_TMP}" "${HEADER}"; then
    mv "${HEADER_TMP}" "${HEADER}"
    echo "note: C header updated" >&2
else
    rm "${HEADER_TMP}"
fi
