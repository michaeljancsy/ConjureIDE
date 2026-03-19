#!/bin/bash
set -euo pipefail

# Previously patched AU identity for worktree builds (WT01 subtype).
# Disabled: PluginKit only allows one registration per bundle ID, so the
# worktree's WT01 was never actually registered. All builds now use the
# same identity (subtype 0001) so AudioComponentFindNext can find the
# component via the existing PluginKit registration.
#
# Called from the BearBoneExtension target's "Patch AU Identity for Worktree"
# build phase. Always a no-op now.

echo "note: AU identity patching disabled — all builds use subtype 0001" >&2
exit 0
