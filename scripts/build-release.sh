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
ARCHIVE_PATH="$PROJECT_DIR/build/ConjureDSP.xcarchive"
EXPORT_OPTIONS="$PROJECT_DIR/ExportOptions.plist"

echo "=== Building Release archive ==="

xcodebuild archive \
    -project "$PROJECT_DIR/ConjureDSP.xcodeproj" \
    -scheme ConjureDSP \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -arch arm64 \
    ARCHS=arm64 \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    | tail -1

echo "=== Exporting with Developer ID signing ==="

mkdir -p "$OUTPUT_DIR"

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$OUTPUT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    | tail -1

APP_PATH="$OUTPUT_DIR/ConjureDSP.app"

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: Export failed — $APP_PATH not found"
    exit 1
fi

echo "=== Re-signing bundled components for notarization ==="

SIGN_ID="Developer ID Application"
APPEX_PATH="$APP_PATH/Contents/PlugIns/ConjureDSPExtension.appex"
ENTITLEMENTS_DIR="$PROJECT_DIR/ConjureDSPExportAUTemplate"

# Re-sign the export template inside the extension Resources
TEMPLATE_ZIP="$APPEX_PATH/Contents/Resources/ExportTemplate.zip"
if [ -f "$TEMPLATE_ZIP" ]; then
    TEMPLATE_TMP="$OUTPUT_DIR/ExportTemplate_tmp"
    rm -rf "$TEMPLATE_TMP"
    mkdir -p "$TEMPLATE_TMP"
    unzip -q "$TEMPLATE_ZIP" -d "$TEMPLATE_TMP"

    TEMPLATE_APP="$TEMPLATE_TMP/ConjureDSPExportAUTemplate.app"
    TEMPLATE_APPEX="$TEMPLATE_APP/Contents/PlugIns/ConjureDSPExportAUTemplateExtension.appex"

    # Sign inside-out: deepest binaries first
    # 1. Python dylib in extension Frameworks
    if [ -f "$TEMPLATE_APPEX/Contents/Frameworks/libpython3.14t.dylib" ]; then
        codesign --force --sign "$SIGN_ID" --options runtime --timestamp \
            "$TEMPLATE_APPEX/Contents/Frameworks/libpython3.14t.dylib"
    fi
    # 2. Extension appex
    codesign --force --sign "$SIGN_ID" --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS_DIR/ConjureDSPExportAUTemplateExtension/ConjureDSPExportAUTemplateExtension.entitlements" \
        "$TEMPLATE_APPEX"
    # 3. Host app dylibs and executables
    find "$TEMPLATE_APP/Contents/MacOS" -type f \( -name '*.dylib' \) \
        -exec codesign --force --sign "$SIGN_ID" --options runtime --timestamp {} \;
    # 4. Host app bundle
    codesign --force --sign "$SIGN_ID" --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS_DIR/ConjureDSPExportAUTemplate/ConjureDSPExportAUTemplate.entitlements" \
        "$TEMPLATE_APP"

    # Re-zip
    rm "$TEMPLATE_ZIP"
    cd "$TEMPLATE_TMP"
    zip -qry "$TEMPLATE_ZIP" "ConjureDSPExportAUTemplate.app"
    cd "$PROJECT_DIR"
    rm -rf "$TEMPLATE_TMP"
    echo "Re-signed ExportTemplate.zip"
fi

# Re-sign rustc binaries with hardened runtime
RUSTC_DST="$APPEX_PATH/Contents/Resources/rustc-dist"
if [ -d "$RUSTC_DST" ]; then
    codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$RUSTC_DST/bin/rustc"
    find "$RUSTC_DST/lib" -name '*.dylib' -exec codesign --force --sign "$SIGN_ID" --options runtime --timestamp {} \;
    codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$RUSTC_DST/lib/rustlib/aarch64-apple-darwin/bin/rust-lld"
    codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$RUSTC_DST/lib/rustlib/aarch64-apple-darwin/bin/gcc-ld/wasm-ld"
    echo "Re-signed rustc-dist binaries"
fi

# Re-sign the extension and app after modifying their contents.
# Use --preserve-metadata=entitlements to keep the entitlements that xcodebuild
# injected during export (com.apple.application-identifier, team-identifier,
# app-sandbox, etc.) — without these, pkd won't discover the AU extension.
codesign --force --sign "$SIGN_ID" --options runtime --timestamp \
    --preserve-metadata=entitlements "$APPEX_PATH"
codesign --force --sign "$SIGN_ID" --options runtime --timestamp \
    --preserve-metadata=entitlements "$APP_PATH"
echo "Re-signed extension and app"

# Read version from the exported app
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")

echo ""
echo "=== Build complete ==="
echo "App:     $APP_PATH"
echo "Version: $VERSION (build $BUILD)"
echo ""
echo "Next: run scripts/notarize.sh \"$APP_PATH\""
