#!/bin/bash
set -euo pipefail

RUST_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST_PATH="${RUST_DIR}/test_plugin_dsp/Cargo.toml"

# Source cargo environment
if [ -f "$HOME/.cargo/env" ]; then
    . "$HOME/.cargo/env"
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

LIB_DST="${BUILT_PRODUCTS_DIR:-${RUST_DIR}/target}/libtest_plugin_dsp.a"

# Build for each architecture
LIBS=()
for ARCH in ${ARCHS:-arm64}; do
    RUST_TARGET=$(arch_to_rust_target "${ARCH}")
    cargo build --manifest-path "${MANIFEST_PATH}" --target "${RUST_TARGET}" ${CARGO_FLAGS}
    LIBS+=("${RUST_DIR}/target/${RUST_TARGET}/${RUST_BUILD_DIR}/libtest_plugin_dsp.a")
done

# Combine with lipo if multiple architectures, otherwise just copy
if [ ${#LIBS[@]} -gt 1 ]; then
    lipo -create "${LIBS[@]}" -output "${LIB_DST}"
else
    cp "${LIBS[0]}" "${LIB_DST}"
fi

# Regenerate C header
cbindgen --config "${RUST_DIR}/cbindgen.toml" \
         --crate test_plugin_dsp \
         --output "${RUST_DIR}/include/test_plugin_dsp.h" \
         "${RUST_DIR}/test_plugin_dsp"
