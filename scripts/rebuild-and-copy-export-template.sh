#!/bin/bash
set -euo pipefail

# Build the export template and zip it into extension Resources.
# Must be zipped (not a raw .app) to prevent PluginKit from discovering
# the template's embedded .appex and registering it as an AU.
#
# In a git worktree, ensures a real build directory exists (replaces any symlink).

SRCROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TEMPLATE_BUILD="${SRCROOT}/ConjureDSPExportAUTemplate/build"
TEMPLATE_PROJECT="${SRCROOT}/ConjureDSPExportAUTemplate/ConjureDSPExportAUTemplate.xcodeproj"

# In a worktree, the build dir may be a symlink to the main worktree.
# xcodebuild can't use -derivedDataPath through a symlink (fails to create
# the workspace arena), so replace it with a real directory.
if [ -L "${TEMPLATE_BUILD}" ]; then
    echo "note: Replacing export template build symlink with local directory" >&2
    rm "${TEMPLATE_BUILD}"
    mkdir -p "${TEMPLATE_BUILD}"
elif [ ! -d "${TEMPLATE_BUILD}" ]; then
    mkdir -p "${TEMPLATE_BUILD}"
fi

# Always build the export template in Release — Debug builds link against
# Xcode-internal dylibs (__preview.dylib, *.debug.dylib) that don't exist
# outside Xcode, causing the exported AU to crash on load in DAWs.
TEMPLATE_CONFIG="Release"

TEMPLATE_SRC="${TEMPLATE_BUILD}/Build/Products/${TEMPLATE_CONFIG}/ConjureDSPExportAUTemplate.app"
TEMPLATE_DST="${BUILT_PRODUCTS_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/ExportTemplate.zip"
TEMPLATE_BINARY="${TEMPLATE_SRC}/Contents/PlugIns/ConjureDSPExportAUTemplateExtension.appex/Contents/MacOS/ConjureDSPExportAUTemplateExtension"
TEMPLATE_SOURCES="${SRCROOT}/ConjureDSPExportAUTemplate/ConjureDSPExportAUTemplateExtension"

# Detect stale incremental builds: if ANY source file is newer than the
# built extension binary, force a clean first. We hit this in a git worktree
# where a symlink→directory swap (above) leaves xcodebuild's build-database
# confused — incremental build silently produces a "SUCCESS" that doesn't
# actually recompile changed Swift files, leading to exports containing
# yesterday's template. Detecting the gap between source mtime and binary
# mtime is the cheapest robust check.
needs_clean=false
if [ -f "${TEMPLATE_BINARY}" ]; then
    binary_mtime=$(stat -f %m "${TEMPLATE_BINARY}")
    # `find -L` follows symlinks so resources symlinked from the main extension
    # (cdp-ui.js, customui-bridge.js, BundleAssetSchemeHandler.swift) trigger a
    # rebuild when their TARGETS change. Without -L, the symlink's own mtime
    # is used, which never updates when only the target changes — Xcode's
    # incremental build then skips Copy Bundle Resources and the bundled
    # appex contains a stale snapshot of the JS / Swift symlink target.
    # We also include .js/.css/.html so any future symlinked web asset is
    # caught by the same check.
    newest_source_mtime=$(find -L "${TEMPLATE_SOURCES}" -type f \( -name "*.swift" -o -name "*.m" -o -name "*.mm" -o -name "*.c" -o -name "*.cpp" -o -name "*.h" -o -name "*.plist" -o -name "*.entitlements" -o -name "*.js" -o -name "*.css" -o -name "*.html" \) -exec stat -f %m {} \; | sort -n | tail -1)
    if [ -n "${newest_source_mtime}" ] && [ "${newest_source_mtime}" -gt "${binary_mtime}" ]; then
        echo "note: Template binary is older than template sources — forcing clean build" >&2
        needs_clean=true
    fi
else
    # No binary yet → first build, no clean needed.
    :
fi

# Build the export template. Use env -i to prevent the parent build's
# environment (extension build settings) from leaking into the template
# build. Without this, inherited env vars cause the Swift compiler to
# generate an extension entry point (_NSExtensionMain) instead of the
# app's _main, crashing the exported app on launch. The template project
# reads DEVELOPMENT_TEAM from ../Config/Base.xcconfig (+ Local.xcconfig),
# the same as the main project, so no signing overrides are needed here.
if [ -f "${TEMPLATE_PROJECT}/project.pbxproj" ]; then
    if [ "${needs_clean}" = "true" ]; then
        echo "Cleaning export template (${TEMPLATE_CONFIG})..."
        env -i HOME="$HOME" PATH="$PATH" DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}" \
            xcodebuild -project "${TEMPLATE_PROJECT}" \
            -scheme ConjureDSPExportAUTemplate \
            -configuration "${TEMPLATE_CONFIG}" \
            -arch arm64 \
            -derivedDataPath "${TEMPLATE_BUILD}" \
            clean \
            2>&1 | tail -1
    fi
    echo "Building export template (${TEMPLATE_CONFIG})..."
    env -i HOME="$HOME" PATH="$PATH" DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}" \
        xcodebuild -project "${TEMPLATE_PROJECT}" \
        -scheme ConjureDSPExportAUTemplate \
        -configuration "${TEMPLATE_CONFIG}" \
        -arch arm64 \
        -derivedDataPath "${TEMPLATE_BUILD}" \
        build \
        2>&1 | tail -1
fi

# Post-build sanity check: if sources are STILL newer than the built
# binary after xcodebuild claimed success, fail loudly. Catches any future
# incremental-build regression that silently ships yesterday's code.
# `find -L` + .js/.css/.html mirror the freshness check above so symlinked
# resources (cdp-ui.js, customui-bridge.js) are tracked through the symlink
# to the actual content that gets bundled.
if [ -f "${TEMPLATE_BINARY}" ]; then
    binary_mtime=$(stat -f %m "${TEMPLATE_BINARY}")
    newest_source_mtime=$(find -L "${TEMPLATE_SOURCES}" -type f \( -name "*.swift" -o -name "*.m" -o -name "*.mm" -o -name "*.c" -o -name "*.cpp" -o -name "*.h" -o -name "*.plist" -o -name "*.entitlements" -o -name "*.js" -o -name "*.css" -o -name "*.html" \) -exec stat -f %m {} \; | sort -n | tail -1)
    if [ -n "${newest_source_mtime}" ] && [ "${newest_source_mtime}" -gt "${binary_mtime}" ]; then
        echo "error: Template sources newer than built binary AFTER build. xcodebuild didn't actually recompile." >&2
        echo "error:   binary mtime: $(date -r "${binary_mtime}")" >&2
        echo "error:   newest source mtime: $(date -r "${newest_source_mtime}")" >&2
        exit 1
    fi
fi

if [ -d "$TEMPLATE_SRC" ]; then
    # Always re-zip. The previous "skip if zip is newer than .app dir" check
    # was unreliable: the .app DIRECTORY's mtime doesn't update when only
    # files inside it change (e.g. a Copy Bundle Resources phase rewriting
    # cdp-ui.js content), so the skip would wrongly say "up to date" and
    # bundle a stale ExportTemplate.zip while the template build itself
    # was correct. Zipping costs ~1s for ~16MB; that's cheaper than another
    # round of "wait, the bundled JS is stale AGAIN" debugging.
    echo "Zipping export template from $TEMPLATE_SRC"
    rm -f "$TEMPLATE_DST"
    cd "$(dirname "$TEMPLATE_SRC")"
    zip -qry "$TEMPLATE_DST" "$(basename "$TEMPLATE_SRC")"
else
    echo "warning: Export template not built at $TEMPLATE_SRC" >&2
    echo "warning: Run: cd ConjureDSPExportAUTemplate && xcodebuild -scheme ConjureDSPExportAUTemplate -configuration ${TEMPLATE_CONFIG} -arch arm64 -derivedDataPath build build" >&2
fi
