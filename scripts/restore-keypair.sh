#!/bin/bash
# Restores the Ed25519 license signing key from macOS Keychain.
# Usage: scripts/restore-keypair.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KEYPAIR_FILE="$REPO_ROOT/tools/generate-license/keypair.bin"

SERVICE_NAME="BearBone Ed25519 Signing Key"
ACCOUNT_NAME="production"

# Check if file already exists
if [ -f "$KEYPAIR_FILE" ]; then
    echo "Warning: $KEYPAIR_FILE already exists."
    read -p "Overwrite? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# Retrieve from Keychain
BASE64_KEY=$(security find-generic-password \
    -s "$SERVICE_NAME" \
    -a "$ACCOUNT_NAME" \
    -w 2>/dev/null) || {
    echo "Error: No keypair found in Keychain."
    echo "  Service: $SERVICE_NAME"
    echo "  Account: $ACCOUNT_NAME"
    echo ""
    echo "Back up first with: scripts/backup-keypair.sh"
    exit 1
}

# Decode and write
echo "$BASE64_KEY" | base64 -d > "$KEYPAIR_FILE"

# Verify size
FILE_SIZE=$(wc -c < "$KEYPAIR_FILE" | tr -d ' ')
if [ "$FILE_SIZE" -ne 32 ]; then
    echo "Error: Restored file has unexpected size ($FILE_SIZE bytes, expected 32)"
    rm -f "$KEYPAIR_FILE"
    exit 1
fi

echo "Keypair restored to $KEYPAIR_FILE ($FILE_SIZE bytes)"
