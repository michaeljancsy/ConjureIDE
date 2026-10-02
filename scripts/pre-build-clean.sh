#!/bin/bash
set -e

# Pre-build cleanup: ensure no stale installations or cached AU state interfere
# with the current build.
#
# Runs before compilation on the host app target.

# 1. Local Release builds only: move any installed ConjureDSP.app out of
#    /Applications/ so it doesn't shadow the DerivedData build via PluginKit.
#    A Release build has the same bundle ID as the installed app, and at equal
#    versions PluginKit picks the /Applications copy. Debug builds use their
#    own bundle ID and AU subtype, so they never collide and must not touch
#    the installed app. Archives (ACTION=install) aren't loaded from
#    DerivedData, so they skip this too.
#
#    Gate on CONFIGURATION, not on detecting a test run: under
#    `xcodebuild test`, Xcode passes ACTION=build to build-phase scripts, so
#    ACTION can't tell a test build from a normal one. Test runs use the
#    scheme's Debug configuration.
#
#    Moves to a .dev-backup location so it's recoverable (not deleted).
INSTALLED_APP="/Applications/ConjureDSP.app"
BACKUP_APP="/Applications/ConjureDSP.app.dev-backup"
if [ "${CONFIGURATION:-}" = "Release" ] && [ "${ACTION:-build}" = "build" ] && [ -d "${INSTALLED_APP}" ]; then
    echo "note: Moving ${INSTALLED_APP} to ${BACKUP_APP} to prevent PluginKit shadowing" >&2
    mv "${INSTALLED_APP}" "${BACKUP_APP}"
fi

# 2. Kill AudioComponentRegistrar so it re-reads registrations after build
killall -9 AudioComponentRegistrar 2>/dev/null || true

# 3. Clear AU cache
rm -f ~/Library/Caches/AudioUnitCache/com.apple.audiounits.cache 2>/dev/null || true

exit 0
