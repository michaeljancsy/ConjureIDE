#!/bin/bash
set -euo pipefail

# Patches the built AU extension's Info.plist when building from a git worktree.
# This gives worktree builds a different AU identity (subtype WT01) so they can
# coexist with the main build in DAWs without conflicting.
#
# Called from the TestPluginExtension target's "Patch AU Identity for Worktree"
# build phase. No-op for main repo builds.

SRCROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# Detect if we're in a git worktree
MAIN_WORKTREE=$(git -C "${SRCROOT}" worktree list --porcelain 2>/dev/null | head -1 | sed 's/worktree //')
CURRENT=$(cd "${SRCROOT}" && pwd -P)
MAIN=$(cd "${MAIN_WORKTREE}" 2>/dev/null && pwd -P || echo "")

if [ "${CURRENT}" = "${MAIN}" ] || [ -z "${MAIN}" ]; then
    echo "note: Main repo build — AU identity unchanged" >&2
    exit 0
fi

echo "note: Worktree build detected — patching AU identity" >&2

# Locate the built Info.plist
PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
if [ ! -f "${PLIST}" ]; then
    echo "error: Built Info.plist not found at ${PLIST}" >&2
    exit 1
fi

PLISTBUDDY=/usr/libexec/PlistBuddy
AU_PATH=":NSExtension:NSExtensionAttributes:AudioComponents:0"

${PLISTBUDDY} -c "Set ${AU_PATH}:subtype WT01" "${PLIST}"
${PLISTBUDDY} -c "Set ${AU_PATH}:name Michael Jancsy: TestPluginExtension (Dev)" "${PLIST}"
${PLISTBUDDY} -c "Set ${AU_PATH}:description TestPluginExtension (Dev)" "${PLIST}"

echo "note: AU identity patched — subtype=WT01, name includes (Dev)" >&2
