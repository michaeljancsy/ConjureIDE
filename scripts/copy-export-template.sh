#!/bin/bash
set -euo pipefail

# Zip pre-built export template into extension Resources.
# Must be zipped (not a raw .app) to prevent PluginKit from discovering
# the template's embedded .appex and registering it as an AU.
#
# In a git worktree, auto-symlinks the template build dir from the main worktree.

SRCROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TEMPLATE_BUILD="${SRCROOT}/BearBoneExportAUTemplate/build"

# Auto-symlink template build dir from main worktree if missing
if [ ! -d "${TEMPLATE_BUILD}" ] && [ ! -L "${TEMPLATE_BUILD}" ]; then
    MAIN_WORKTREE=$(git -C "${SRCROOT}" worktree list --porcelain 2>/dev/null | head -1 | sed 's/worktree //')
    if [ -n "${MAIN_WORKTREE}" ] && [ -d "${MAIN_WORKTREE}/BearBoneExportAUTemplate/build" ]; then
        echo "note: Symlinking export template build from main worktree" >&2
        ln -s "${MAIN_WORKTREE}/BearBoneExportAUTemplate/build" "${TEMPLATE_BUILD}"
    fi
fi

TEMPLATE_SRC="${TEMPLATE_BUILD}/Build/Products/Release/BearBoneExportAUTemplate.app"
TEMPLATE_DST="${BUILT_PRODUCTS_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/ExportTemplate.zip"

if [ -d "$TEMPLATE_SRC" ]; then
    echo "Zipping export template from $TEMPLATE_SRC"
    cd "$(dirname "$TEMPLATE_SRC")"
    zip -qry "$TEMPLATE_DST" "$(basename "$TEMPLATE_SRC")"
else
    echo "warning: Export template not built at $TEMPLATE_SRC" >&2
    echo "warning: Run: cd BearBoneExportAUTemplate && xcodebuild -scheme BearBoneExportAUTemplate -configuration Release -arch arm64 build" >&2
fi
