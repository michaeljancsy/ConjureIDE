#!/bin/bash
#
# release.sh — Full release pipeline: build, notarize, package DMG.
#
# Usage: ./scripts/release.sh
#
# Prerequisites:
#   1. Developer ID Application certificate in Keychain
#   2. Notarization credentials stored:
#        xcrun notarytool store-credentials "BearBone-Notarize" \
#          --apple-id "your@email.com" \
#          --team-id "A4R63LAVLS" \
#          --password "xxxx-xxxx-xxxx-xxxx"
#   3. Rust toolchain + bundled Python runtime (rust/setup-python.sh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$PROJECT_DIR/build/release"

echo "========================================"
echo "  BearBone Release Pipeline"
echo "========================================"
echo ""

# Step 1: Build and export
echo "[1/4] Building Release archive..."
"$SCRIPT_DIR/build-release.sh" "$OUTPUT_DIR"

APP_PATH="$OUTPUT_DIR/BearBone.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")

echo ""
echo "[2/4] Notarizing app..."
"$SCRIPT_DIR/notarize.sh" "$APP_PATH"

echo ""
echo "[3/4] Creating DMG..."
DMG_PATH="$OUTPUT_DIR/BearBone-${VERSION}.dmg"
"$SCRIPT_DIR/create-dmg.sh" "$APP_PATH" "$DMG_PATH"

echo ""
echo "[4/4] Notarizing DMG..."
"$SCRIPT_DIR/notarize.sh" "$DMG_PATH"

echo ""
echo "========================================"
echo "  Release complete!"
echo "========================================"
echo ""
echo "  Version: $VERSION (build $BUILD)"
echo "  DMG:     $DMG_PATH"
echo "  Size:    $(du -h "$DMG_PATH" | awk '{print $1}')"
echo ""
echo "  The DMG is signed, notarized, and ready to distribute."
echo ""
