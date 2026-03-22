#!/bin/bash
#
# build-release.sh — Build a Release archive and export with Developer ID signing.
#
# Usage: ./scripts/build-release.sh [output-dir]
#   output-dir: where to place the exported .app (default: build/release)
#
# Requires: Xcode, Developer ID Application certificate in Keychain.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="${1:-$PROJECT_DIR/build/release}"
ARCHIVE_PATH="$PROJECT_DIR/build/BearBone.xcarchive"
EXPORT_OPTIONS="$PROJECT_DIR/ExportOptions.plist"

echo "=== Building Release archive ==="

xcodebuild archive \
    -project "$PROJECT_DIR/BearBone.xcodeproj" \
    -scheme BearBone \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -arch arm64 \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    | tail -1

echo "=== Exporting with Developer ID signing ==="

mkdir -p "$OUTPUT_DIR"

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$OUTPUT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    | tail -1

APP_PATH="$OUTPUT_DIR/BearBone.app"

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: Export failed — $APP_PATH not found"
    exit 1
fi

# Read version from the exported app
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")

echo ""
echo "=== Build complete ==="
echo "App:     $APP_PATH"
echo "Version: $VERSION (build $BUILD)"
echo ""
echo "Next: run scripts/notarize.sh \"$APP_PATH\""
