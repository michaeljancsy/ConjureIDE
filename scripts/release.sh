#!/bin/bash
#
# release.sh — Release an already-built DMG: generate appcast and upload to R2.
#
# Usage: ./scripts/release.sh [build-dir]
#   build-dir: directory containing ConjureDSP.app and DMG (default: build/release)
#
# Prerequisites:
#   1. A built DMG from build.sh (run build.sh --notarize first for public releases)
#   2. Sparkle EdDSA keypair (see build-and-release.sh header for setup)
#   3. Cloudflare R2 bucket `conjuredsp-updates` with rclone configured

set -euo pipefail

# Ensure Homebrew binaries are on PATH (needed for rclone/node)
export PATH="/opt/homebrew/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="${1:-$PROJECT_DIR/build/release}"
R2_BUCKET="conjuredsp-updates"
UPDATES_BASE_URL="https://updates.conjuredsp.com"

APP_PATH="$OUTPUT_DIR/ConjureDSP.app"
if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: No built app found at $APP_PATH"
    echo "Run ./scripts/build.sh first."
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")
DMG_PATH="$OUTPUT_DIR/ConjureDSP-${VERSION}.dmg"

if [ ! -f "$DMG_PATH" ]; then
    echo "ERROR: No DMG found at $DMG_PATH"
    echo "Run ./scripts/build.sh first."
    exit 1
fi

echo "========================================"
echo "  ConjureDSP Release"
echo "========================================"
echo ""
echo "  Version: $VERSION (build $BUILD)"
echo "  DMG:     $DMG_PATH"
echo ""

# Step 1: Generate Sparkle appcast
echo "[1/2] Generating Sparkle appcast..."
# APPCAST_DIR is preserved across release runs: it accumulates every historic
# DMG so generate_appcast can emit a feed containing all versions (enables
# rollback via versions.html below). On a fresh machine we pull any missing
# DMGs down from R2 before regenerating.
APPCAST_DIR="$OUTPUT_DIR/appcast"
mkdir -p "$APPCAST_DIR"

# Sync historic DMGs from R2 for multi-version appcast.
# Best-effort — if rclone isn't configured, we just use what's on disk.
if command -v rclone >/dev/null 2>&1; then
    echo "  Syncing historic DMGs from R2..."
    rclone copy "r2:${R2_BUCKET}" "$APPCAST_DIR" --include "*.dmg" 2>/dev/null || true
fi

# Copy AFTER rclone sync so the fresh build isn't overwritten by a stale R2 copy
cp "$DMG_PATH" "$APPCAST_DIR/"

# Delete stale appcast.xml so generate_appcast regenerates from scratch.
# A leftover appcast.xml causes it to skip archives it considers "already processed",
# silently dropping new versions from the feed.
rm -f "$APPCAST_DIR/appcast.xml"

# generate_appcast scans the directory for archives, extracts version info
# from embedded app bundles, signs with the EdDSA private key stored in the
# login Keychain (put there by `generate_keys`), and produces appcast.xml.
SPARKLE_BIN=$(find "$PROJECT_DIR/.build" ~/Library/Developer/Xcode/DerivedData -name "generate_appcast" -type f 2>/dev/null | head -1 || true)
if [ -n "$SPARKLE_BIN" ]; then
    "$SPARKLE_BIN" --maximum-versions 0 "$APPCAST_DIR"
    echo "  Appcast: $APPCAST_DIR/appcast.xml"

    # Generate versions.html from the appcast — linked from the app's
    # "Previous Versions…" menu item. Users can download any prior DMG
    # directly from this page to roll back.
    VERSIONS_HTML="$APPCAST_DIR/versions.html"
    /usr/bin/python3 - "$APPCAST_DIR/appcast.xml" "$VERSIONS_HTML" "$UPDATES_BASE_URL" <<'PY'
import sys, html, datetime, xml.etree.ElementTree as ET
from email.utils import parsedate_to_datetime
appcast_path, out_path, base_url = sys.argv[1], sys.argv[2], sys.argv[3]
tree = ET.parse(appcast_path)
items = []
for item in tree.getroot().iter("item"):
    title = (item.findtext("title") or "").strip()
    pub_date_raw = (item.findtext("pubDate") or "").strip()
    enclosure = item.find("enclosure")
    if enclosure is None:
        continue
    url = enclosure.get("url", "")
    if not url.startswith("http"):
        url = base_url.rstrip("/") + "/" + url.lstrip("/")
    version = enclosure.get("{http://www.andymatuschak.org/xml-namespaces/sparkle}shortVersionString") or title
    try:
        sort_dt = parsedate_to_datetime(pub_date_raw) if pub_date_raw else None
    except (TypeError, ValueError):
        sort_dt = None
    if sort_dt is None:
        sort_dt = datetime.datetime.min.replace(tzinfo=datetime.timezone.utc)
    elif sort_dt.tzinfo is None:
        sort_dt = sort_dt.replace(tzinfo=datetime.timezone.utc)
    items.append((sort_dt, version, pub_date_raw, url))
items.sort(key=lambda row: row[0], reverse=True)
items = [(v, d, u) for _, v, d, u in items]
rows = "\n".join(
    f'<li><a href="{html.escape(u)}">ConjureDSP {html.escape(v)}</a>'
    f'<span class="date">{html.escape(d)}</span></li>'
    for v, d, u in items
)
doc = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<title>ConjureDSP — Previous Versions</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
body{{font:15px -apple-system,BlinkMacSystemFont,sans-serif;max-width:620px;margin:3em auto;padding:0 1em;color:#222}}
h1{{font-size:1.4em}} p{{color:#555}}
ul{{list-style:none;padding:0}}
li{{padding:.6em 0;border-bottom:1px solid #eee;display:flex;justify-content:space-between;align-items:baseline;gap:1em}}
a{{color:#0a64d8;text-decoration:none;font-weight:500}} a:hover{{text-decoration:underline}}
.date{{color:#888;font-size:.9em}}
</style></head><body>
<h1>ConjureDSP — Previous Versions</h1>
<p>Download any previous version below. To install, open the DMG and drag
ConjureDSP to your Applications folder, replacing the current copy. Your
presets, license, and settings are preserved.</p>
<ul>
{rows}
</ul>
</body></html>
"""
open(out_path, "w").write(doc)
PY
    echo "  versions.html: $VERSIONS_HTML"
else
    echo "  WARNING: generate_appcast not found. Build the project first or run:"
    echo "    xcrun --find generate_appcast"
    echo "  Then re-run this script, or manually generate the appcast."
fi

echo ""
if ! command -v rclone >/dev/null 2>&1; then
    echo "ERROR: rclone is not installed. Install it and configure the 'r2' remote."
    echo "  brew install rclone"
    exit 1
fi
if [ ! -f "$APPCAST_DIR/appcast.xml" ]; then
    echo "ERROR: appcast.xml was not generated. Cannot upload."
    exit 1
fi

echo "[2/2] Uploading to R2..."
R2_REMOTE="r2:${R2_BUCKET}"
DMG_NAME="ConjureDSP-${VERSION}.dmg"
echo "  Uploading $DMG_NAME..."
rclone copyto "$APPCAST_DIR/${DMG_NAME}" "${R2_REMOTE}/${DMG_NAME}" \
    --header-upload "Content-Type: application/x-apple-diskimage"
echo "  Uploading appcast.xml..."
rclone copyto "$APPCAST_DIR/appcast.xml" "${R2_REMOTE}/appcast.xml" \
    --header-upload "Content-Type: application/xml"
if [ -f "$APPCAST_DIR/versions.html" ]; then
    echo "  Uploading versions.html..."
    rclone copyto "$APPCAST_DIR/versions.html" "${R2_REMOTE}/versions.html" \
        --header-upload "Content-Type: text/html; charset=utf-8"
fi
# Upload Sparkle delta files (small binary diffs for incremental updates)
for delta in "$APPCAST_DIR"/*.delta; do
    [ -f "$delta" ] || continue
    DELTA_NAME=$(basename "$delta")
    echo "  Uploading delta $DELTA_NAME..."
    rclone copyto "$delta" "${R2_REMOTE}/${DELTA_NAME}" \
        --header-upload "Content-Type: application/octet-stream"
done
echo "  Uploaded to ${UPDATES_BASE_URL}/"

echo ""
echo "========================================"
echo "  Release complete!"
echo "========================================"
echo ""
echo "  Version: $VERSION (build $BUILD)"
echo "  DMG:     $DMG_PATH"
echo "  Size:    $(du -h "$DMG_PATH" | awk '{print $1}')"
if [ -f "$APPCAST_DIR/appcast.xml" ]; then
echo "  Appcast: $APPCAST_DIR/appcast.xml"
fi
echo ""
