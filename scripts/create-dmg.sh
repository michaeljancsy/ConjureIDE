#!/bin/bash
#
# create-dmg.sh — Package a .app into a distributable DMG.
#
# Usage: ./scripts/create-dmg.sh <path-to-app> [output-dmg]
#
# Creates a DMG with the app and an Applications symlink for drag-to-install.

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <path-to-app> [output-dmg]"
    exit 1
fi

APP_PATH="$1"

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: $APP_PATH not found"
    exit 1
fi

# Read version from the app
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
APP_NAME=$(basename "$APP_PATH" .app)
DMG_NAME="${APP_NAME}-${VERSION}"
OUTPUT_DMG="${2:-$(dirname "$APP_PATH")/${DMG_NAME}.dmg}"
TEMP_DMG="$(dirname "$APP_PATH")/${DMG_NAME}-temp.dmg"
STAGING_DIR=$(mktemp -d)

echo "=== Creating DMG: $DMG_NAME ==="

# Stage the contents
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

# Install instructions. Step 2 is load-bearing: macOS (PluginKit) only
# registers the AUv3 extension when the app is launched and Gatekeeper
# approval is recorded, so a user who drags the app in and goes straight
# to their DAW will not see the plugin.
INSTRUCTIONS_NAME="Install Instructions.txt"
cat > "$STAGING_DIR/$INSTRUCTIONS_NAME" <<'TXT'
Installing ConjureIDE

1. Drag ConjureIDE to Applications.
2. Open ConjureIDE once. macOS registers the AUv3 plugin at first
   launch; until then it will not appear in any DAW.
3. Restart your DAW and insert ConjureIDE from Audio Units > Effects.
TXT

# Calculate size (app size + 10% headroom for HFS+ overhead, minimum 50MB)
SIZE_KB=$(du -sk "$STAGING_DIR" | awk '{print $1}')
HEADROOM=$((SIZE_KB / 10))
[ "$HEADROOM" -lt 51200 ] && HEADROOM=51200
SIZE_KB=$((SIZE_KB + HEADROOM))

# Create temporary read-write DMG
hdiutil create \
    -srcfolder "$STAGING_DIR" \
    -volname "$APP_NAME" \
    -fs HFS+ \
    -size "${SIZE_KB}k" \
    -format UDRW \
    "$TEMP_DMG"

# Set Finder window appearance
MOUNT_DIR=$(hdiutil attach -readwrite -noverify "$TEMP_DMG" | grep "/Volumes/" | sed 's/.*\/Volumes/\/Volumes/')

# Address the volume by its actual mount name, not $APP_NAME — if another
# volume named "$APP_NAME" is already mounted (e.g. a release DMG), macOS
# mounts ours as "$APP_NAME 2" and "tell disk" would hit the wrong disk.
VOL_NAME=$(basename "$MOUNT_DIR")

osascript <<EOF
tell application "Finder"
    tell disk "$VOL_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {100, 100, 640, 480}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 80
        set position of item "$APP_NAME.app" of container window to {140, 150}
        set position of item "Applications" of container window to {400, 150}
        -- Match by prefix: Finder may hide the .txt extension, in which
        -- case the item's AppleScript name drops it too.
        set position of (first item of container window whose name begins with "Install Instructions") to {270, 300}
        close
    end tell
end tell
EOF

# Give Finder time to write .DS_Store
sync
sleep 1

hdiutil detach "$MOUNT_DIR" -quiet

# Convert to compressed read-only DMG
rm -f "$OUTPUT_DMG"
hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUTPUT_DMG"

# Clean up
rm -f "$TEMP_DMG"
rm -rf "$STAGING_DIR"

echo ""
echo "=== DMG created ==="
echo "Output: $OUTPUT_DMG"
echo "Size:   $(du -h "$OUTPUT_DMG" | awk '{print $1}')"
