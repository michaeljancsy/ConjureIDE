#!/bin/bash
set -euo pipefail

# Kill AudioComponentRegistrar so macOS re-discovers AU registrations.
# Runs for all configurations (Debug/Release) since switching between them
# changes the registered AU identity.
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

exit 0
