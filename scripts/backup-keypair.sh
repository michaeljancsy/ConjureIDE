#!/bin/bash
# Backs up the Ed25519 license signing key to macOS Keychain.
# Usage: scripts/backup-keypair.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KEYPAIR_FILE="$REPO_ROOT/tools/generate-license/keypair.bin"

SERVICE_NAME="BearBone Ed25519 Signing Key"
ACCOUNT_NAME="production"

# If in a worktree, look for keypair.bin in the main repo
if [ ! -f "$KEYPAIR_FILE" ]; then
    MAIN_WORKTREE=$(cd "$REPO_ROOT" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's|/\.git$||')
    if [ -n "$MAIN_WORKTREE" ] && [ "$MAIN_WORKTREE" != "$REPO_ROOT" ]; then
        KEYPAIR_FILE="$MAIN_WORKTREE/tools/generate-license/keypair.bin"
    fi
fi

if [ ! -f "$KEYPAIR_FILE" ]; then
    echo "Error: keypair.bin not found"
    echo "Run 'cd tools/generate-license && cargo run -- --init' first."
    exit 1
fi

# Verify file size (Ed25519 private key is exactly 32 bytes)
FILE_SIZE=$(wc -c < "$KEYPAIR_FILE" | tr -d ' ')
if [ "$FILE_SIZE" -ne 32 ]; then
    echo "Error: keypair.bin has unexpected size ($FILE_SIZE bytes, expected 32)"
    exit 1
fi

# Base64-encode the private key for Keychain storage
BASE64_KEY=$(base64 < "$KEYPAIR_FILE")

# Store in login keychain (-U updates if already exists)
security add-generic-password \
    -U \
    -s "$SERVICE_NAME" \
    -a "$ACCOUNT_NAME" \
    -D "Ed25519 private key" \
    -w "$BASE64_KEY"

echo "Keypair backed up to macOS Keychain."
echo "  Service: $SERVICE_NAME"
echo "  Account: $ACCOUNT_NAME"
echo ""
echo "To restore: scripts/restore-keypair.sh"
