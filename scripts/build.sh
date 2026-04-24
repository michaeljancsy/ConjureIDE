#!/bin/bash
#
# build.sh — Build a Release archive, sign, package DMG, and optionally notarize.
#
# Usage: ./scripts/build.sh [--notarize] [--version X.Y.Z] [--build N] [--beta] [output-dir]
#   --notarize:      submit the app and DMG to Apple's notary service (takes a few minutes)
#   --version X.Y.Z: set MARKETING_VERSION before building (updates all targets in pbxproj)
#   --build N:       set CURRENT_PROJECT_VERSION before building (updates all targets in pbxproj)
#   --beta:          build with BETA_BUILD Swift flag — plugin runs unlicensed for
#                    7 days from the build date then reverts to Demo (no 60s timer,
#                    no "DEMO" badge — shows "BETA" instead). Use this when the
#                    subscription infrastructure is unavailable.
#   output-dir:      where to place the exported .app and DMG (default: build/release)
#
# Requires: Xcode, Developer ID Application certificate in Keychain,
#   Developer ID provisioning profiles installed for both bundle IDs.
#
# The Release configuration in the Xcode project is set to Manual signing with
# Developer ID Application identity and provisioning profile specifiers. This
# produces an archive that's already properly signed for distribution.

set -euo pipefail

NOTARIZE=false
SET_VERSION=""
SET_BUILD=""
BETA_BUILD=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --notarize) NOTARIZE=true; shift ;;
        --version)  SET_VERSION="$2"; shift 2 ;;
        --build)    SET_BUILD="$2"; shift 2 ;;
        --beta)     BETA_BUILD=true; shift ;;
        *) break ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PBXPROJ="$PROJECT_DIR/ConjureDSP.xcodeproj/project.pbxproj"
OUTPUT_DIR="${1:-$PROJECT_DIR/build/release}"

# Update version/build in pbxproj if requested (only main project, not ExportAUTemplate)
if [ -n "$SET_VERSION" ]; then
    sed -i '' "s/MARKETING_VERSION = [^;]*/MARKETING_VERSION = $SET_VERSION/" "$PBXPROJ"
    echo "Set MARKETING_VERSION = $SET_VERSION"
fi
if [ -n "$SET_BUILD" ]; then
    sed -i '' "s/CURRENT_PROJECT_VERSION = [^;]*/CURRENT_PROJECT_VERSION = $SET_BUILD/" "$PBXPROJ"
    echo "Set CURRENT_PROJECT_VERSION = $SET_BUILD"
fi
# Ensure OUTPUT_DIR is absolute (needed because we cd into temp dirs during signing)
case "$OUTPUT_DIR" in /*) ;; *) OUTPUT_DIR="$PROJECT_DIR/$OUTPUT_DIR" ;; esac
ARCHIVE_PATH="$PROJECT_DIR/build/ConjureDSP.xcarchive"

if $BETA_BUILD; then
    echo "=== Building Release archive (BETA — 7-day window from build date) ==="
else
    echo "=== Building Release archive ==="
fi

BETA_FLAGS=()
if $BETA_BUILD; then
    BETA_FLAGS=(SWIFT_ACTIVE_COMPILATION_CONDITIONS="BETA_BUILD")
fi

xcodebuild archive \
    -project "$PROJECT_DIR/ConjureDSP.xcodeproj" \
    -scheme ConjureDSP \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=macOS" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    "${BETA_FLAGS[@]}" \
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

# Remove extension's python-dist entirely — the terminal provisions the runtime
# to the App Group container; the extension reads from there at runtime.
# (libpython3.14t.dylib stays in the extension's Frameworks/ for linking.)
if [ -d "$APPEX_RES/python-dist" ]; then
    rm -rf "$APPEX_RES/python-dist"
    echo "Removed extension python-dist (provisioned by terminal)"
fi

# Strip terminal's python-dist: remove test suites, __pycache__, pip, and unused stdlib
TERMINAL_PATH="$APP_PATH/Contents/Library/ConjureDSPTerminal.app"
TERMINAL_RES="$TERMINAL_PATH/Contents/Resources"
if [ -d "$TERMINAL_RES/python-dist" ]; then
    PYDIST="$TERMINAL_RES/python-dist/lib/python3.14t"
    # Test suites and caches
    rm -rf "$PYDIST/test"
    find "$TERMINAL_RES/python-dist" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
    find "$PYDIST/site-packages" -type d -name 'tests' -exec rm -rf {} + 2>/dev/null || true
    # pip (not needed at runtime — uv handles package management)
    rm -rf "$PYDIST/site-packages/pip" "$PYDIST/site-packages/pip-"*.dist-info
    # Unused stdlib modules (not needed for DSP scripting)
    rm -rf "$PYDIST/tkinter" "$PYDIST/idlelib" "$PYDIST/turtledemo" "$PYDIST/ensurepip" "$PYDIST/lib2to3" "$PYDIST/pydoc_data"
    rm -f "$PYDIST/turtle.py" "$PYDIST/doctest.py"
    rm -f "$PYDIST/lib-dynload/_tkinter"*.so "$PYDIST/lib-dynload/_ctypes_test"*.so
    # Type stubs, Cython defs, C headers (not needed at runtime)
    find "$PYDIST/site-packages" -name '*.pyi' -delete 2>/dev/null || true
    find "$PYDIST/site-packages" -name '*.pxd' -delete 2>/dev/null || true
    find "$PYDIST/site-packages" -name '*.h' -delete 2>/dev/null || true
    # Test .so files in site-packages (e.g. _ctest, _cytest, _test_internal)
    find "$PYDIST/site-packages" -name '*test*' -name '*.so' -delete 2>/dev/null || true
    # numpy f2py (Fortran-to-Python compiler, not needed for DSP)
    rm -rf "$PYDIST/site-packages/numpy/f2py"
    echo "Stripped terminal python-dist"
fi

# Remove sanitizer runtimes from extension's rustc-dist (~10MB)
if [ -d "$APPEX_RES/rustc-dist" ]; then
    rm -f "$APPEX_RES/rustc-dist/lib/rustlib/aarch64-apple-darwin/lib"/librustc-stable_rt.*.dylib
    echo "Stripped extension rustc sanitizer runtimes"
fi

# Remove terminal's rustc-dist entirely — it finds the extension's copy at runtime
if [ -d "$TERMINAL_RES/rustc-dist" ]; then
    rm -rf "$TERMINAL_RES/rustc-dist"
    echo "Removed terminal rustc-dist (uses extension's copy)"
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

    # 5. Verify the re-signed appex still has the sandbox entitlement.
    # If it doesn't, pkd silently rejects every export ("plug-ins must be
    # sandboxed") and exported AUs never appear in DAWs. `codesign
    # --entitlements <file>` overwrites with the file as-is, so any key
    # Xcode auto-merges (like app-sandbox via ENABLE_APP_SANDBOX) must also
    # be present in the source .entitlements file or this assertion fires.
    if ! codesign -d --entitlements - "$TEMPLATE_APPEX" 2>&1 | grep -q "com.apple.security.app-sandbox"; then
        echo "error: ExportTemplate appex is missing com.apple.security.app-sandbox after re-sign." >&2
        echo "       PluginKit will reject every exported AU. Add the key to" >&2
        echo "       ConjureDSPExportAUTemplateExtension.entitlements." >&2
        exit 1
    fi

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
RUSTC_ENT="$PROJECT_DIR/scripts/rustc-entitlements.plist"
if [ -d "$RUSTC_DST" ]; then
    # rustc needs disable-library-validation to dlopen proc-macro dylibs compiled by cargo
    codesign --force --sign "$SIGN_ID" --options runtime --timestamp --entitlements "$RUSTC_ENT" "$RUSTC_DST/bin/rustc"
    # Sign remaining executables (cargo, etc.) without the entitlement
    find "$RUSTC_DST/bin" -type f -perm +111 ! -name rustc \
        -exec codesign --force --sign "$SIGN_ID" --options runtime --timestamp {} \;
    find "$RUSTC_DST/lib" -name '*.dylib' -exec codesign --force --sign "$SIGN_ID" --options runtime --timestamp {} \;
    codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$RUSTC_DST/lib/rustlib/aarch64-apple-darwin/bin/rust-lld"
    codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$RUSTC_DST/lib/rustlib/aarch64-apple-darwin/bin/gcc-ld/wasm-ld"
    echo "Re-signed rustc-dist binaries"
fi

# Re-sign embedded ConjureDSPTerminal.app
if [ -d "$TERMINAL_PATH" ]; then
    # Sign Python .so/.dylib files in terminal
    if [ -d "$TERMINAL_RES/python-dist" ]; then
        find "$TERMINAL_RES/python-dist" \( -name '*.so' -o -name '*.dylib' \) -type f \
            -exec codesign --force --sign "$SIGN_ID" --options runtime --timestamp {} \;
        # Sign python3 binary
        [ -f "$TERMINAL_RES/python-dist/bin/python3" ] && \
            codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$TERMINAL_RES/python-dist/bin/python3"
        echo "Re-signed terminal python-dist binaries"
    fi
    # Sign uv binary
    [ -f "$TERMINAL_RES/uv" ] && \
        codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$TERMINAL_RES/uv"
    # Sign the terminal app bundle
    codesign --force --sign "$SIGN_ID" --options runtime --timestamp \
        --entitlements "$PROJECT_DIR/ConjureDSPTerminal/ConjureDSPTerminal.entitlements" \
        "$TERMINAL_PATH"
    echo "Re-signed ConjureDSPTerminal"
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

# Read version from the built app
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")

echo ""
if $NOTARIZE; then
    echo "=== Notarizing app ==="
    "$SCRIPT_DIR/notarize.sh" "$APP_PATH"
else
    echo "=== Skipping notarization (pass --notarize to enable) ==="
fi

echo ""
echo "=== Creating DMG ==="
DMG_PATH="$OUTPUT_DIR/ConjureDSP-${VERSION}.dmg"
"$SCRIPT_DIR/create-dmg.sh" "$APP_PATH" "$DMG_PATH"

if $NOTARIZE; then
    echo ""
    echo "=== Notarizing DMG ==="
    "$SCRIPT_DIR/notarize.sh" "$DMG_PATH"
fi

echo ""
echo "=== Build complete ==="
echo "App:     $APP_PATH"
echo "DMG:     $DMG_PATH"
echo "Version: $VERSION (build $BUILD)"
echo "Size:    $(du -h "$DMG_PATH" | awk '{print $1}')"
if $NOTARIZE; then
    echo "Status:  Notarized"
else
    echo "Status:  NOT notarized (local testing only)"
fi
echo ""
