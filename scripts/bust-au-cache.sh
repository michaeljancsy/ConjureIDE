#!/bin/bash
set -euo pipefail

# Post-build: force-register the freshly-built app with LaunchServices and
# restart PluginKit + AudioComponentRegistrar so the just-built extension
# is always the one that gets loaded. This handles switching between
# worktrees, Debug/Release configurations, and DerivedData rebuilds.
#
# Skipped during test actions to avoid interfering with the test runner.

# Detect test actions: ACTION is set by xcodebuild (build, test, etc.)
if [ "${ACTION:-build}" = "test" ] || [ "${ACTION:-build}" = "build-for-testing" ]; then
    echo "note: Test action — skipping AU cache bust" >&2
    exit 0
fi

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister
APP_PATH="${BUILT_PRODUCTS_DIR:-}/ConjureDSP.app"

# Resolve the real (canonical) path of the current build so we can compare
# against LaunchServices entries and skip unregistering ourselves.
REAL_APP_PATH="$(cd "${APP_PATH}" 2>/dev/null && pwd -P)" || REAL_APP_PATH=""

# Unregister all OTHER ConjureDSP debug/release builds from LaunchServices.
# Without this, PluginKit may serve a stale extension from a different
# worktree or DerivedData directory that shares the same bundle ID.
{ $LSREGISTER -dump | grep -B20 "identifier:.*com\.MichaelJancsy\.ConjureDSP" | grep "path:" | sed 's/.*path:[[:space:]]*//' | sed 's/ (0x.*//' || true; } | while read -r registered_path; do
    # Resolve symlinks for accurate comparison
    real_registered="$(cd "${registered_path}" 2>/dev/null && pwd -P)" || real_registered=""
    if [ -n "$REAL_APP_PATH" ] && [ "$real_registered" = "$REAL_APP_PATH" ]; then
        continue  # Don't unregister the current build
    fi
    # Only unregister DerivedData builds (don't touch /Applications or exports)
    case "$registered_path" in
        */Library/Developer/Xcode/DerivedData/*)
            $LSREGISTER -u "$registered_path" 2>/dev/null && \
                echo "note: Unregistered competing build: ${registered_path}" >&2 || true
            ;;
    esac
done

if [ -d "${APP_PATH}" ]; then
    # Force-register the just-built app with LaunchServices.
    # The -f flag updates even if an entry already exists, ensuring
    # PluginKit always discovers THIS build's embedded extension.
    $LSREGISTER -f -R -trusted "${APP_PATH}" 2>/dev/null && \
        echo "note: Registered app with LaunchServices: ${APP_PATH}" >&2 || \
        echo "warning: lsregister failed for ${APP_PATH}" >&2
fi

# Kill AudioComponentRegistrar so it re-reads AU registrations on next query.
killall -9 AudioComponentRegistrar 2>/dev/null && \
    echo "note: Killed AudioComponentRegistrar" >&2 || true

# Kill PluginKit daemon so it re-discovers extensions from LaunchServices.
# Without this, pkd may serve a stale extension from a previous build
# when switching between worktrees or configurations.
killall -9 pkd 2>/dev/null && \
    echo "note: Killed pkd for extension re-discovery" >&2 || true

exit 0
