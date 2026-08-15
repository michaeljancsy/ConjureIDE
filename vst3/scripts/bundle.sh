#!/usr/bin/env bash
#
# Builds Bedrock and lays it out as a VST3 bundle for the host platform.
#
#   ./scripts/bundle.sh [--debug] [--install]
#
# VST3 is a bundle format on every platform, including Windows and Linux, and hosts locate the
# binary by a path that encodes the architecture. Getting that layout wrong is the usual reason
# a freshly built plugin never shows up in a DAW, so it is scripted rather than described.

set -euo pipefail

PRODUCT="Bedrock"
PROFILE="release"
CARGO_FLAGS="--release"
INSTALL=0

while [ $# -gt 0 ]; do
    case "$1" in
        --debug)   PROFILE="debug"; CARGO_FLAGS="" ;;
        --install) INSTALL=1 ;;
        -h|--help)
            sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
OUT="$ROOT/out"
BUNDLE="$OUT/$PRODUCT.vst3"

echo "==> building ($PROFILE)"
# shellcheck disable=SC2086
cargo build -p bedrock-vst3 $CARGO_FLAGS

rm -rf "$BUNDLE"

case "$(uname -s)" in
Darwin)
    # A macOS VST3 is a real bundle: Contents/MacOS/<name> plus an Info.plist. Build both
    # architectures when the toolchain has them, so the plugin loads in Intel and Apple
    # Silicon hosts alike.
    mkdir -p "$BUNDLE/Contents/MacOS"

    ARCH_BINARIES=()
    for target in aarch64-apple-darwin x86_64-apple-darwin; do
        if rustup target list --installed 2>/dev/null | grep -qx "$target"; then
            echo "==> building $target"
            # shellcheck disable=SC2086
            cargo build -p bedrock-vst3 $CARGO_FLAGS --target "$target"
            ARCH_BINARIES+=("$ROOT/target/$target/$PROFILE/libbedrock.dylib")
        fi
    done

    if [ ${#ARCH_BINARIES[@]} -gt 0 ]; then
        lipo -create "${ARCH_BINARIES[@]}" -output "$BUNDLE/Contents/MacOS/$PRODUCT"
    else
        cp "$ROOT/target/$PROFILE/libbedrock.dylib" "$BUNDLE/Contents/MacOS/$PRODUCT"
    fi

    cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$PRODUCT</string>
    <key>CFBundleIdentifier</key><string>com.conjuredsp.bedrock</string>
    <key>CFBundleName</key><string>$PRODUCT</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleSignature</key><string>????</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>0.1.0</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>10.13</string>
</dict>
</plist>
PLIST
    printf 'BNDL????' > "$BUNDLE/Contents/PkgInfo"

    # Hosts refuse unsigned bundles on recent macOS; ad-hoc is enough for local use.
    codesign --force --sign - --timestamp=none "$BUNDLE" 2>/dev/null \
        || echo "    (codesign unavailable; sign manually before distributing)"

    INSTALL_DIR="$HOME/Library/Audio/Plug-Ins/VST3"
    ;;

Linux)
    case "$(uname -m)" in
        x86_64)  ARCH_DIR="x86_64-linux" ;;
        aarch64) ARCH_DIR="aarch64-linux" ;;
        *)       ARCH_DIR="$(uname -m)-linux" ;;
    esac
    mkdir -p "$BUNDLE/Contents/$ARCH_DIR"
    cp "$ROOT/target/$PROFILE/libbedrock.so" "$BUNDLE/Contents/$ARCH_DIR/$PRODUCT.so"
    INSTALL_DIR="$HOME/.vst3"
    ;;

MINGW*|MSYS*|CYGWIN*)
    mkdir -p "$BUNDLE/Contents/x86_64-win"
    cp "$ROOT/target/$PROFILE/bedrock.dll" "$BUNDLE/Contents/x86_64-win/$PRODUCT.vst3"
    INSTALL_DIR="$PROGRAMFILES/Common Files/VST3"
    ;;

*)
    echo "unsupported platform: $(uname -s)" >&2
    exit 1
    ;;
esac

echo "==> bundled at $BUNDLE"

if [ "$INSTALL" -eq 1 ]; then
    mkdir -p "$INSTALL_DIR"
    rm -rf "${INSTALL_DIR:?}/$PRODUCT.vst3"
    cp -R "$BUNDLE" "$INSTALL_DIR/"
    echo "==> installed to $INSTALL_DIR/$PRODUCT.vst3"
    echo "    Rescan plugins in your host; Bedrock Track and Bedrock Vision appear under Fx|Analyzer."
fi
