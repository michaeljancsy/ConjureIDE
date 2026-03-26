#!/bin/bash
#
# release.sh — Full release pipeline: build, notarize, package DMG.
#
# Usage: ./scripts/release.sh
#
# Prerequisites:
#   1. Developer ID Application certificate in Keychain
#   2. Notarization credentials stored:
#        xcrun notarytool store-credentials "ConjureDSP-Notarize" \
#          --apple-id "your@email.com" \
#          --team-id "A4R63LAVLS" \
#          --password "xxxx-xxxx-xxxx-xxxx"
#   3. Rust toolchain + bundled Python runtime (rust/setup-python.sh)
#   4. Sparkle EdDSA keypair: on first run, generate_appcast will prompt you
#      to create one. Store the private key in Keychain (Sparkle does this
#      automatically) and add the public key to SUPublicEDKey in Info.plist.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$PROJECT_DIR/build/release"

echo "========================================"
echo "  ConjureDSP Release Pipeline"
echo "========================================"
echo ""

# Step 1: Build and export
echo "[1/4] Building Release archive..."
"$SCRIPT_DIR/build-release.sh" "$OUTPUT_DIR"

APP_PATH="$OUTPUT_DIR/ConjureDSP.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")

echo ""
echo "[2/4] Notarizing app..."
"$SCRIPT_DIR/notarize.sh" "$APP_PATH"

echo ""
echo "[3/4] Creating DMG..."
DMG_PATH="$OUTPUT_DIR/ConjureDSP-${VERSION}.dmg"
"$SCRIPT_DIR/create-dmg.sh" "$APP_PATH" "$DMG_PATH"

echo ""
echo "[4/4] Notarizing DMG..."
"$SCRIPT_DIR/notarize.sh" "$DMG_PATH"

echo ""
echo "[5/5] Generating Sparkle appcast..."
APPCAST_DIR="$OUTPUT_DIR/appcast"
mkdir -p "$APPCAST_DIR"
cp "$DMG_PATH" "$APPCAST_DIR/"
# generate_appcast scans the directory for archives, extracts version info
# from embedded app bundles, signs with EdDSA, and produces appcast.xml.
# On first run it will create an EdDSA keypair and store it in Keychain.
SPARKLE_BIN=$(find "$PROJECT_DIR/.build" ~/Library/Developer/Xcode/DerivedData -name "generate_appcast" -type f 2>/dev/null | head -1)
if [ -n "$SPARKLE_BIN" ]; then
    "$SPARKLE_BIN" "$APPCAST_DIR"
    echo "  Appcast: $APPCAST_DIR/appcast.xml"
else
    echo "  WARNING: generate_appcast not found. Build the project first or run:"
    echo "    xcrun --find generate_appcast"
    echo "  Then re-run this script, or manually generate the appcast."
fi

echo ""
echo "========================================"
echo "  Release complete!"
echo "========================================"
echo ""
echo "  Version: $VERSION (build $BUILD)"
echo "  DMG:     $DMG_PATH"
echo "  Size:    $(du -h "$DMG_PATH" | awk '{print $1}')"
if [ -f "$APPCAST_DIR/appcast.xml" ]; then
echo "  Appcast: $APPCAST_DIR/appcast.xml"
fi
echo ""
echo "  The DMG is signed, notarized, and ready to distribute."
echo "  Upload the DMG and appcast.xml to your update server."
echo ""
