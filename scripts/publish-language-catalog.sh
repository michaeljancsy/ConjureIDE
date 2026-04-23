#!/bin/bash
#
# publish-language-catalog.sh — Upload language-module tarballs + an atomically
# generated catalog.json to the R2 bucket backing updates.conjuredsp.com.
#
# Source of truth for tarballs: build/language-modules/*.tar.gz plus their
# sibling .sha256 file (produced by scripts/build-python-module.sh and
# scripts/build-rustc-module.sh).
#
# Usage:
#   ./scripts/publish-language-catalog.sh [--dry-run]
#
# Reuses the same Cloudflare R2 bucket as the main-app appcast — modules live
# under updates.conjuredsp.com/language-modules/ rather than requiring a
# separate bucket / domain. If we later decide to move them to a dedicated
# bucket, update R2_BUCKET + PUBLIC_BASE_URL below and the `defaultCatalogURL`
# in Shared/LanguageModuleCatalog.swift.
#
# Idempotent: re-running with the same tarballs on disk uploads identical
# bytes and regenerates an identical catalog.json. Safe to run from a clean
# machine as long as the tarballs and their .sha256 siblings are present.

set -euo pipefail

export PATH="/opt/homebrew/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MODULES_DIR="$PROJECT_DIR/build/language-modules"

R2_BUCKET="conjuredsp-updates"
R2_PREFIX="language-modules"
PUBLIC_BASE_URL="https://updates.conjuredsp.com/${R2_PREFIX}"

DRY_RUN=false
if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=true
fi

if [ ! -d "$MODULES_DIR" ]; then
    echo "ERROR: No language-modules directory at $MODULES_DIR" >&2
    echo "       Run scripts/build-python-module.sh and/or scripts/build-rustc-module.sh first." >&2
    exit 1
fi

if ! command -v rclone >/dev/null 2>&1; then
    echo "ERROR: rclone is not installed. brew install rclone" >&2
    exit 1
fi

# Expected module names & how they map to a catalog description. Adding a
# new module? Teach description_for() its human-readable text.
# (Plain function instead of associative array because macOS ships bash 3.2.)
description_for() {
    case "$1" in
        python) echo "Free-threaded Python 3.14 + numpy + scipy — required for all Python-based presets" ;;
        rustc)  echo "Rust 1.93 compiler + wasm32-wasip1 sysroot + cargo — required to edit or author new Rust presets" ;;
        *)      echo "Language module ${1}" ;;
    esac
}

MIN_APP_VERSION="1.0.15"

echo "========================================"
echo "  ConjureDSP Language Module Publish"
echo "========================================"
echo "  Source: $MODULES_DIR"
echo "  Target: r2:${R2_BUCKET}/${R2_PREFIX}/"
echo "  Public: ${PUBLIC_BASE_URL}/"
$DRY_RUN && echo "  DRY RUN — no uploads"
echo ""

CATALOG_ENTRIES=()

shopt -s nullglob
for TARBALL in "$MODULES_DIR"/*.tar.gz; do
    BASENAME="$(basename "$TARBALL")"
    # Expect name-version-arch.tar.gz — match the leading module name up to
    # the first "-" that precedes a digit (= start of version).
    if [[ "$BASENAME" =~ ^([a-z][a-z0-9_]*)-([^-]+)-([^-]+)\.tar\.gz$ ]]; then
        NAME="${BASH_REMATCH[1]}"
        VERSION="${BASH_REMATCH[2]}"
        ARCH="${BASH_REMATCH[3]}"
    else
        echo "skip: $BASENAME — filename doesn't match <name>-<version>-<arch>.tar.gz" >&2
        continue
    fi

    SHA_FILE="${TARBALL%.tar.gz}.sha256"
    if [ ! -f "$SHA_FILE" ]; then
        echo "skip: $BASENAME — missing sibling $(basename "$SHA_FILE")" >&2
        continue
    fi
    SHA="$(tr -d '[:space:]' < "$SHA_FILE")"
    SIZE_MB="$(du -m "$TARBALL" | awk '{print $1}')"
    DESCRIPTION="$(description_for "$NAME")"
    URL="${PUBLIC_BASE_URL}/${BASENAME}"

    echo "→ ${NAME} ${VERSION} (${SIZE_MB} MB)"
    echo "    sha256: ${SHA}"
    echo "    url:    ${URL}"

    if ! $DRY_RUN; then
        rclone copyto "$TARBALL" "r2:${R2_BUCKET}/${R2_PREFIX}/${BASENAME}" \
            --header-upload "Content-Type: application/gzip"
    fi

    # Build the JSON object line for catalog.json (single-line, jq-composable).
    CATALOG_ENTRIES+=( "\"${NAME}\": {\"version\":\"${VERSION}\",\"sizeMB\":${SIZE_MB},\"sha256\":\"${SHA}\",\"minApp\":\"${MIN_APP_VERSION}\",\"url\":\"${URL}\",\"description\":\"${DESCRIPTION}\"}" )
done

if [ "${#CATALOG_ENTRIES[@]}" -eq 0 ]; then
    echo "ERROR: no tarballs matched in $MODULES_DIR" >&2
    exit 1
fi

CATALOG_JSON="$MODULES_DIR/catalog.json"
{
    echo "{"
    echo "  \"schemaVersion\": 1,"
    echo "  \"modules\": {"
    for i in "${!CATALOG_ENTRIES[@]}"; do
        if [ "$i" -lt $((${#CATALOG_ENTRIES[@]} - 1)) ]; then
            echo "    ${CATALOG_ENTRIES[$i]},"
        else
            echo "    ${CATALOG_ENTRIES[$i]}"
        fi
    done
    echo "  }"
    echo "}"
} > "$CATALOG_JSON"

echo ""
echo "→ catalog.json"
if command -v jq >/dev/null 2>&1; then
    jq . "$CATALOG_JSON"
else
    cat "$CATALOG_JSON"
fi

if ! $DRY_RUN; then
    rclone copyto "$CATALOG_JSON" "r2:${R2_BUCKET}/${R2_PREFIX}/catalog.json" \
        --header-upload "Content-Type: application/json"
fi

echo ""
echo "========================================"
if $DRY_RUN; then
    echo "  Dry run complete — nothing uploaded."
else
    echo "  Published to ${PUBLIC_BASE_URL}/"
fi
echo "========================================"
