#!/bin/bash
set -euo pipefail

# Post-build: kill AudioComponentRegistrar and re-register the freshly-built
# app with LaunchServices so PluginKit discovers the embedded extension.
# Skipped during test actions to avoid interfering with the test runner.

# Detect test actions: ACTION is set by xcodebuild (build, test, etc.)
if [ "${ACTION:-build}" = "test" ] || [ "${ACTION:-build}" = "build-for-testing" ]; then
    echo "note: Test action — skipping AU cache bust" >&2
    exit 0
fi

# Kill AudioComponentRegistrar so it re-reads AU registrations on next query.
# The registrar restarts on demand via launchd.
killall -9 AudioComponentRegistrar 2>/dev/null && \
    echo "note: Killed AudioComponentRegistrar for cache bust" >&2 || \
    echo "note: AudioComponentRegistrar not running (nothing to kill)" >&2

# Re-register the freshly-built host app with LaunchServices.
# This triggers PluginKit to discover the embedded extension, ensuring
# the DerivedData build is the active registration.
APP_PATH="${BUILT_PRODUCTS_DIR:-}/BearBone.app"
if [ -d "${APP_PATH}" ]; then
    /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f -R -trusted "${APP_PATH}" 2>/dev/null && \
        echo "note: Re-registered app with LaunchServices: ${APP_PATH}" >&2 || \
        echo "warning: lsregister failed for ${APP_PATH}" >&2
fi

exit 0
