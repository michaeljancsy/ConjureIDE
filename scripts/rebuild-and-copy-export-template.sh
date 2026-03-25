#!/bin/bash
set -euo pipefail

# Build the export template and zip it into extension Resources.
# Must be zipped (not a raw .app) to prevent PluginKit from discovering
# the template's embedded .appex and registering it as an AU.
#
# In a git worktree, auto-symlinks the template build dir from the main worktree.

SRCROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TEMPLATE_BUILD="${SRCROOT}/ConjureDSPExportAUTemplate/build"
TEMPLATE_PROJECT="${SRCROOT}/ConjureDSPExportAUTemplate/ConjureDSPExportAUTemplate.xcodeproj"

# Auto-symlink template build dir from main worktree if missing
if [ ! -d "${TEMPLATE_BUILD}" ] && [ ! -L "${TEMPLATE_BUILD}" ]; then
    MAIN_WORKTREE=$(git -C "${SRCROOT}" worktree list --porcelain 2>/dev/null | head -1 | sed 's/worktree //')
    if [ -n "${MAIN_WORKTREE}" ] && [ -d "${MAIN_WORKTREE}/ConjureDSPExportAUTemplate/build" ]; then
        echo "note: Symlinking export template build from main worktree" >&2
        ln -s "${MAIN_WORKTREE}/ConjureDSPExportAUTemplate/build" "${TEMPLATE_BUILD}"
    fi
fi

TEMPLATE_CONFIG="${CONFIGURATION:-Release}"

# Build the export template (incremental — fast no-op if nothing changed).
# Use env -i to prevent the parent build's environment (extension build settings)
# from leaking into the template build. Without this, inherited env vars cause
# the Swift compiler to generate an extension entry point (_NSExtensionMain)
# instead of the app's _main, crashing the exported app on launch.
if [ -f "${TEMPLATE_PROJECT}/project.pbxproj" ]; then
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

TEMPLATE_SRC="${TEMPLATE_BUILD}/Build/Products/${TEMPLATE_CONFIG}/ConjureDSPExportAUTemplate.app"
TEMPLATE_DST="${BUILT_PRODUCTS_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/ExportTemplate.zip"

if [ -d "$TEMPLATE_SRC" ]; then
    echo "Zipping export template from $TEMPLATE_SRC"
    cd "$(dirname "$TEMPLATE_SRC")"
    zip -qry "$TEMPLATE_DST" "$(basename "$TEMPLATE_SRC")"
else
    echo "warning: Export template not built at $TEMPLATE_SRC" >&2
    echo "warning: Run: cd ConjureDSPExportAUTemplate && xcodebuild -scheme ConjureDSPExportAUTemplate -configuration ${TEMPLATE_CONFIG} -arch arm64 -derivedDataPath build build" >&2
fi
