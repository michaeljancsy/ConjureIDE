#!/bin/bash
set -e

# Pre-build cleanup: ensure no stale installations or cached AU state interfere
# with the current build.
#
# Runs before compilation on the host app target.
# Skipped during test actions to avoid interfering with the test runner.

if [ "${ACTION:-build}" = "test" ] || [ "${ACTION:-build}" = "build-for-testing" ]; then
    echo "note: Test action — skipping pre-build clean" >&2
    exit 0
fi

# 1. Move any installed BearBone.app out of /Applications/ so it doesn't
#    shadow the DerivedData build via PluginKit. Moves to a .dev-backup
#    location so it's recoverable (not deleted).
INSTALLED_APP="/Applications/BearBone.app"
BACKUP_APP="/Applications/BearBone.app.dev-backup"
if [ -d "${INSTALLED_APP}" ]; then
    echo "note: Moving ${INSTALLED_APP} to ${BACKUP_APP} to prevent PluginKit shadowing" >&2
    mv "${INSTALLED_APP}" "${BACKUP_APP}"
fi

# 2. Kill AudioComponentRegistrar so it re-reads registrations after build
killall -9 AudioComponentRegistrar 2>/dev/null || true

# 3. Clear AU cache
rm -f ~/Library/Caches/AudioUnitCache/com.apple.audiounits.cache 2>/dev/null || true

exit 0
