#!/bin/bash
#
# upload-dsyms.sh — Upload a release archive's debug symbols to Sentry, then
# confirm Sentry holds every one of them.
#
# Usage:
#   ./scripts/upload-dsyms.sh --check                  # credentials preflight only
#   ./scripts/upload-dsyms.sh path/to/ConjureDSP.xcarchive
#
# build.sh calls --check before archiving (so a missing or bad token fails in
# seconds, not after the archive), then passes the archive right after
# archiving. Every failure exits non-zero — nothing is skipped silently.
#
# The destination is pinned to org michael-jancsy / project conjuredsp.
# sentry-cli's [defaults] are not trusted: ~/.sentryclirc on the release Mac
# defaults to a different project (conjurealign).
#
# Auth token (org:ci scope is enough for both upload and verification),
# first match wins:
#   1. SENTRY_AUTH_TOKEN environment variable
#   2. token= in the [auth] section of ~/.sentryclirc
# A project-level .sentryclirc is deliberately not consulted: it is gitignored,
# so it exists in one checkout and not in others.

set -euo pipefail

# Homebrew on Apple Silicon (sentry-cli)
export PATH="/opt/homebrew/bin:$PATH"

SENTRY_ORG="michael-jancsy"
SENTRY_PROJECT="conjuredsp"
export SENTRY_URL="${SENTRY_URL:-https://sentry.io}"
# Don't let a stray .env in a parent directory feed settings to sentry-cli.
export SENTRY_LOAD_DOTENV=0

die() { echo "error: $*" >&2; exit 1; }

usage() {
    echo "Usage: $0 --check | <path/to/ConjureDSP.xcarchive>" >&2
    exit 2
}

[ $# -eq 1 ] || usage

command -v sentry-cli >/dev/null 2>&1 \
    || die "sentry-cli not found. Install with: brew install getsentry/tools/sentry-cli"

if [ -z "${SENTRY_AUTH_TOKEN:-}" ] && [ -f "$HOME/.sentryclirc" ]; then
    SENTRY_AUTH_TOKEN=$(awk '
        /^[[:space:]]*\[/ { in_auth = ($0 ~ /^[[:space:]]*\[auth\][[:space:]]*$/); next }
        in_auth && /^[[:space:]]*token[[:space:]]*=/ {
            sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit
        }' "$HOME/.sentryclirc")
fi
[ -n "${SENTRY_AUTH_TOKEN:-}" ] \
    || die "no Sentry auth token. Set SENTRY_AUTH_TOKEN, or add token=<org:ci token> under [auth] in ~/.sentryclirc."
# sentry-cli prefers this over any .sentryclirc it finds, so upload and
# verification use the same token.
export SENTRY_AUTH_TOKEN

DSYMS_ENDPOINT="projects/$SENTRY_ORG/$SENTRY_PROJECT/files/dsyms/"

# GET a Sentry API path and print the response body. The token reaches curl on
# stdin rather than argv, so it never appears in `ps` output.
sentry_get() {
    local out status
    out=$(printf 'header = "Authorization: Bearer %s"\n' "$SENTRY_AUTH_TOKEN" \
        | curl --silent --show-error --config - --write-out '\n%{http_code}' "$SENTRY_URL/api/0/$1") \
        || die "could not reach $SENTRY_URL"
    status="${out##*$'\n'}"
    [ "$status" = "200" ] || die "Sentry API returned HTTP $status for $1: ${out%$'\n'*}"
    printf '%s' "${out%$'\n'*}"
}

# A query that matches nothing still needs a valid token with access to the
# project, so HTTP 200 here proves the upload will be accepted.
check_access() {
    sentry_get "${DSYMS_ENDPOINT}?query=00000000-0000-0000-0000-000000000000" >/dev/null
    echo "Sentry access OK: token can reach $SENTRY_ORG/$SENTRY_PROJECT"
}

if [ "$1" = "--check" ]; then
    check_access
    exit 0
fi

ARCHIVE="${1%/}"
DSYMS="$ARCHIVE/dSYMs"
[ -d "$DSYMS" ] || die "no dSYMs folder at $DSYMS"
shopt -s nullglob
DSYM_BUNDLES=("$DSYMS"/*.dSYM)
[ ${#DSYM_BUNDLES[@]} -gt 0 ] || die "$DSYMS contains no .dSYM bundles"

# python-build-standalone ships libpython without a dSYM, but its symbol table
# still names the interpreter frames in extension crashes.
LIBPYTHON="$ARCHIVE/Products/Applications/ConjureDSP.app/Contents/PlugIns/ConjureDSPExtension.appex/Contents/Frameworks/libpython3.14t.dylib"
[ -f "$LIBPYTHON" ] || die "libpython not found at $LIBPYTHON"

check_access

echo "Uploading debug files to $SENTRY_ORG/$SENTRY_PROJECT..."
sentry-cli debug-files upload \
    --org "$SENTRY_ORG" --project "$SENTRY_PROJECT" \
    --include-sources --wait-for 300 \
    "$DSYMS" "$LIBPYTHON"

# has_debug_file UUID FEATURE — succeeds if Sentry holds a Mach-O debug file
# for UUID that provides FEATURE ("debug" = DWARF from a dSYM, "symtab" = the
# symbol table of a plain binary).
has_debug_file() {
    local body
    # `|| exit`: errexit is off inside a function called from an `if`, and an
    # API failure must stop the script rather than read as "missing".
    body=$(sentry_get "${DSYMS_ENDPOINT}?query=$1") || exit 1
    /usr/bin/python3 -c '
import json, sys
uuid, feature = sys.argv[1], sys.argv[2]
files = json.loads(sys.stdin.read())
sys.exit(0 if any(
    f.get("uuid") == uuid
    and f.get("symbolType") == "macho"
    and feature in ((f.get("data") or {}).get("features") or [])
    for f in files) else 1)
' "$1" "$2" <<<"$body"
}

# dwarfdump prints one line per Mach-O slice: "UUID: 6BF204F9-... (arm64) /path/to/binary".
# Prefix the feature each one must have; the path goes last so spaces survive `read`.
# Collected up front so a dwarfdump failure stops the script instead of
# silently dropping files from the check. `&&`, not a newline: macOS bash 3.2
# does not carry `set -e` into $(...).
SLICES=$(
    dwarfdump --uuid "${DSYM_BUNDLES[@]}" | sed 's/^UUID: /debug /' &&
    dwarfdump --uuid "$LIBPYTHON" | sed 's/^UUID: /symtab /'
)

echo "Verifying on Sentry..."
total=0
missing=0
while read -r feature uuid arch file; do
    uuid=$(echo "$uuid" | tr '[:upper:]' '[:lower:]')
    total=$((total + 1))
    if has_debug_file "$uuid" "$feature"; then
        echo "  ok       $uuid $arch $(basename "$file")"
    else
        echo "  MISSING  $uuid $arch $(basename "$file")"
        missing=$((missing + 1))
    fi
done <<<"$SLICES"

[ "$total" -gt 0 ] || die "dwarfdump found no UUIDs in $ARCHIVE"
if [ "$missing" -gt 0 ]; then
    die "$missing of $total debug files are not on Sentry ($SENTRY_ORG/$SENTRY_PROJECT). Crashes from this build will not symbolicate. Re-run: $0 \"$ARCHIVE\""
fi
echo "All $total debug files are on Sentry ($SENTRY_ORG/$SENTRY_PROJECT)"
