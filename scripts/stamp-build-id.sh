#!/bin/bash
set -euo pipefail

# Stamps a timestamp-derived build ID into the built extension's Info.plist.
# This gives each build a unique integer ID so you always know which build is running.
#
# Called from the BearBoneExtension target's "Stamp Build ID" build phase.

PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
if [ ! -f "${PLIST}" ]; then
    echo "error: Built Info.plist not found at ${PLIST}" >&2
    exit 1
fi

BUILD_ID=$(date +%s)

/usr/libexec/PlistBuddy -c "Add :BuildID integer ${BUILD_ID}" "${PLIST}" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :BuildID ${BUILD_ID}" "${PLIST}"

echo "note: Stamped BuildID=${BUILD_ID}" >&2
