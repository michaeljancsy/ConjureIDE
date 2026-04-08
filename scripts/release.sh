#!/bin/bash
#
# release.sh — Full release pipeline: build, notarize, package DMG.
#
# Usage: ./scripts/release.sh
#
# Prerequisites:
#   1. Developer ID Application certificate in Keychain
#   2. Notarization credentials stored:
#        xcrun notarytool store-credentials "ConjureDSP-Notarize" \
#          --apple-id "your@email.com" \
#          --team-id "A4R63LAVLS" \
#          --password "xxxx-xxxx-xxxx-xxxx"
#   3. Rust toolchain + bundled Python runtime (rust/setup-python.sh)
#   4. Sparkle EdDSA keypair: run the `generate_keys` tool once (bundled
#      alongside generate_appcast in the Sparkle SPM artifacts — find it with
#      `find ~/Library/Developer/Xcode/DerivedData -name generate_keys -type f`).
#      It stores the private key in the login Keychain and prints the public
#      key. Paste the public key into INFOPLIST_KEY_SUPublicEDKey in the
#      Release build settings of ConjureDSP.xcodeproj. This is already done
#      for the main dev machine; only needed when setting up a new signer.
#   5. Cloudflare R2 bucket `conjuredsp-updates` with custom domain
#      updates.conjuredsp.com. Wrangler CLI authenticated (same auth as the
#      subscriptions Worker in server/). Uploads are skipped with a warning
#      if wrangler is not installed.

set -euo pipefail

SKIP_NOTARIZE=false
if [[ "${1:-}" == "--skip-notarize" ]]; then
    SKIP_NOTARIZE=true
    shift
fi

# Ensure Homebrew binaries are on PATH (needed for wrangler/node)
export PATH="/opt/homebrew/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$PROJECT_DIR/build/release"
R2_BUCKET="conjuredsp-updates"
UPDATES_BASE_URL="https://updates.conjuredsp.com"

echo "========================================"
echo "  ConjureDSP Release Pipeline"
echo "========================================"
echo ""

# Step 1: Build and export
echo "[1/6] Building Release archive..."
"$SCRIPT_DIR/build-release.sh" "$OUTPUT_DIR"

APP_PATH="$OUTPUT_DIR/ConjureDSP.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")

echo ""
if $SKIP_NOTARIZE; then
    echo "[2/6] Skipping app notarization (--skip-notarize)"
else
    echo "[2/6] Notarizing app..."
    "$SCRIPT_DIR/notarize.sh" "$APP_PATH"
fi

echo ""
echo "[3/6] Creating DMG..."
DMG_PATH="$OUTPUT_DIR/ConjureDSP-${VERSION}.dmg"
"$SCRIPT_DIR/create-dmg.sh" "$APP_PATH" "$DMG_PATH"

echo ""
if $SKIP_NOTARIZE; then
    echo "[4/6] Skipping DMG notarization (--skip-notarize)"
else
    echo "[4/6] Notarizing DMG..."
    "$SCRIPT_DIR/notarize.sh" "$DMG_PATH"
fi

echo ""
echo "[5/6] Generating Sparkle appcast..."
# APPCAST_DIR is preserved across release runs: it accumulates every historic
# DMG so generate_appcast can emit a feed containing all versions (enables
# rollback via versions.html below). On a fresh machine we pull any missing
# DMGs down from R2 before regenerating.
APPCAST_DIR="$OUTPUT_DIR/appcast"
mkdir -p "$APPCAST_DIR"
cp "$DMG_PATH" "$APPCAST_DIR/"

# Sync historic DMGs from R2 for multi-version appcast.
# Best-effort — if rclone isn't configured, we just use what's on disk.
if command -v rclone >/dev/null 2>&1; then
    echo "  Syncing historic DMGs from R2..."
    rclone copy "r2:${R2_BUCKET}" "$APPCAST_DIR" --include "*.dmg" 2>/dev/null || true
fi

# generate_appcast scans the directory for archives, extracts version info
# from embedded app bundles, signs with the EdDSA private key stored in the
# login Keychain (put there by `generate_keys`), and produces appcast.xml.
SPARKLE_BIN=$(find "$PROJECT_DIR/.build" ~/Library/Developer/Xcode/DerivedData -name "generate_appcast" -type f 2>/dev/null | head -1)
if [ -n "$SPARKLE_BIN" ]; then
    "$SPARKLE_BIN" "$APPCAST_DIR"
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
    # Parse RFC 822 pubDate for sorting; fall back to epoch so unparseable
    # entries sort last rather than crashing.
    try:
        sort_dt = parsedate_to_datetime(pub_date_raw) if pub_date_raw else None
    except (TypeError, ValueError):
        sort_dt = None
    if sort_dt is None:
        sort_dt = datetime.datetime.min.replace(tzinfo=datetime.timezone.utc)
    elif sort_dt.tzinfo is None:
        sort_dt = sort_dt.replace(tzinfo=datetime.timezone.utc)
    items.append((sort_dt, version, pub_date_raw, url))
# Sort newest first by publication date. Robust against pre-release version
# strings like "1.0-beta" that would break a naive version-string sort.
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
echo "[6/6] Uploading to R2..."
R2_REMOTE="r2:${R2_BUCKET}"
if command -v rclone >/dev/null 2>&1 && [ -f "$APPCAST_DIR/appcast.xml" ]; then
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
else
    echo "  WARNING: skipping upload. Install rclone and configure the 'r2' remote,"
    echo "  or manually upload these files to the R2 bucket"
    echo "  ${R2_BUCKET} (served at ${UPDATES_BASE_URL}/):"
    echo "    - $APPCAST_DIR/ConjureDSP-${VERSION}.dmg"
    echo "    - $APPCAST_DIR/appcast.xml"
    [ -f "$APPCAST_DIR/versions.html" ] && echo "    - $APPCAST_DIR/versions.html"
fi

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
echo "  The DMG is signed, notarized, and ready to distribute."
echo "  Upload the DMG and appcast.xml to your update server."
echo ""
