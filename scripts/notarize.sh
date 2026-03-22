#!/bin/bash
#
# notarize.sh — Submit an app or DMG to Apple's notary service and staple the ticket.
#
# Usage: ./scripts/notarize.sh <path-to-app-or-dmg>
#
# Prerequisites:
#   Store your app-specific password in the Keychain:
#     xcrun notarytool store-credentials "BearBone-Notarize" \
#       --apple-id "your@email.com" \
#       --team-id "A4R63LAVLS" \
#       --password "xxxx-xxxx-xxxx-xxxx"
#
#   Generate an app-specific password at https://appleid.apple.com/account/manage
#   (Security → App-Specific Passwords → Generate)

set -euo pipefail

KEYCHAIN_PROFILE="BearBone-Notarize"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <path-to-app-or-dmg>"
    echo ""
    echo "First-time setup:"
    echo "  xcrun notarytool store-credentials \"$KEYCHAIN_PROFILE\" \\"
    echo "    --apple-id \"your@email.com\" \\"
    echo "    --team-id \"A4R63LAVLS\" \\"
    echo "    --password \"xxxx-xxxx-xxxx-xxxx\""
    exit 1
fi

TARGET="$1"

if [ ! -e "$TARGET" ]; then
    echo "ERROR: $TARGET not found"
    exit 1
fi

# If target is a .app, zip it for submission
if [ -d "$TARGET" ] && [[ "$TARGET" == *.app ]]; then
    ZIP_PATH="${TARGET%.app}.zip"
    echo "=== Zipping $TARGET ==="
    ditto -c -k --keepParent "$TARGET" "$ZIP_PATH"
    SUBMIT_PATH="$ZIP_PATH"
else
    SUBMIT_PATH="$TARGET"
fi

echo "=== Submitting to Apple notary service ==="
echo "This typically takes 5-15 minutes..."
echo ""

xcrun notarytool submit "$SUBMIT_PATH" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait

# Clean up zip if we created one
if [ -d "$TARGET" ] && [[ "$TARGET" == *.app ]]; then
    rm -f "$ZIP_PATH"
fi

echo ""
echo "=== Stapling notarization ticket ==="

xcrun stapler staple "$TARGET"

echo ""
echo "=== Notarization complete ==="
echo "Stapled: $TARGET"
