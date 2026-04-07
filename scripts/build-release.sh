#!/bin/bash
#
# build-release.sh — Build a Release archive and export with Developer ID signing.
#
# Usage: ./scripts/build-release.sh [output-dir]
#   output-dir: where to place the exported .app (default: build/release)
#
# Requires: Xcode, Developer ID Application certificate in Keychain,
#   Developer ID provisioning profiles installed for both bundle IDs.
#
# The Release configuration in the Xcode project is set to Manual signing with
# Developer ID Application identity and provisioning profile specifiers. This
# produces an archive that's already properly signed for distribution.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="${1:-$PROJECT_DIR/build/release}"
# Ensure OUTPUT_DIR is absolute (needed because we cd into temp dirs during signing)
case "$OUTPUT_DIR" in /*) ;; *) OUTPUT_DIR="$PROJECT_DIR/$OUTPUT_DIR" ;; esac
ARCHIVE_PATH="$PROJECT_DIR/build/ConjureDSP.xcarchive"

echo "=== Building Release archive ==="

xcodebuild archive \
    -project "$PROJECT_DIR/ConjureDSP.xcodeproj" \
    -scheme ConjureDSP \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=macOS" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    | tail -1

echo "=== Extracting app from archive ==="

mkdir -p "$OUTPUT_DIR"

# Copy the app directly from the archive. The archive is already signed with
# Developer ID Application (configured in the project's Release build settings).
APP_PATH="$OUTPUT_DIR/ConjureDSP.app"
rm -rf "$APP_PATH"
cp -R "$ARCHIVE_PATH/Products/Applications/ConjureDSP.app" "$APP_PATH"

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: Archive extraction failed — $APP_PATH not found"
    exit 1
fi

echo "=== Stripping unnecessary files to reduce bundle size ==="

APPEX_RES="$APP_PATH/Contents/PlugIns/ConjureDSPExtension.appex/Contents/Resources"

# Remove Python test suites, __pycache__, and pip (~140MB)
if [ -d "$APPEX_RES/python-dist" ]; then
    rm -rf "$APPEX_RES/python-dist/lib/python3.14t/test"
    find "$APPEX_RES/python-dist" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
    find "$APPEX_RES/python-dist/lib/python3.14t/site-packages" -type d -name 'tests' -exec rm -rf {} + 2>/dev/null || true
    rm -rf "$APPEX_RES/python-dist/lib/python3.14t/site-packages/pip"
    rm -rf "$APPEX_RES/python-dist/lib/python3.14t/site-packages/pip-"*.dist-info
    echo "Stripped Python test/cache/pip files"
fi

# Remove sanitizer runtimes and cargo from rustc-dist (~39MB)
if [ -d "$APPEX_RES/rustc-dist" ]; then
    rm -f "$APPEX_RES/rustc-dist/lib/rustlib/aarch64-apple-darwin/lib"/librustc-stable_rt.*.dylib
    rm -f "$APPEX_RES/rustc-dist/bin/cargo"
    echo "Stripped rustc sanitizer runtimes and cargo"
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

# Re-sign Sparkle framework binaries
SPARKLE_FW="$APP_PATH/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE_FW" ]; then
    find "$SPARKLE_FW" -type f -perm +111 \( -name '*.app' -prune -o -print \) | while read -r bin; do
        file "$bin" 2>/dev/null | grep -q "Mach-O" && \
            codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$bin"
    done
    # Sign .app bundles inside Sparkle
    find "$SPARKLE_FW" -name '*.app' -type d | while read -r app; do
        codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$app"
    done
    # Sign .xpc bundles inside Sparkle
    find "$SPARKLE_FW" -name '*.xpc' -type d | while read -r xpc; do
        codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$xpc"
    done
    # Sign the framework itself
    codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$SPARKLE_FW"
    echo "Re-signed Sparkle framework"
fi

# Re-sign bundled Python distribution (.so and .dylib files)
PYTHON_DIST="$APPEX_PATH/Contents/Resources/python-dist"
if [ -d "$PYTHON_DIST" ]; then
    find "$PYTHON_DIST" \( -name '*.so' -o -name '*.dylib' \) -type f \
        -exec codesign --force --sign "$SIGN_ID" --options runtime --timestamp {} \;
    echo "Re-signed python-dist binaries"
fi

# Re-sign rustc binaries with hardened runtime
RUSTC_DST="$APPEX_PATH/Contents/Resources/rustc-dist"
if [ -d "$RUSTC_DST" ]; then
    # Sign all executables and dylibs in rustc-dist
    find "$RUSTC_DST/bin" -type f -perm +111 \
        -exec codesign --force --sign "$SIGN_ID" --options runtime --timestamp {} \;
    find "$RUSTC_DST/lib" -name '*.dylib' -exec codesign --force --sign "$SIGN_ID" --options runtime --timestamp {} \;
    codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$RUSTC_DST/lib/rustlib/aarch64-apple-darwin/bin/rust-lld"
    codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$RUSTC_DST/lib/rustlib/aarch64-apple-darwin/bin/gcc-ld/wasm-ld"
    echo "Re-signed rustc-dist binaries"
fi

# Re-sign the extension and app after modifying their contents.
# Use --preserve-metadata=entitlements to keep the entitlements that xcodebuild
# injected during archiving (com.apple.application-identifier, team-identifier,
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
