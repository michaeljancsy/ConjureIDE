#!/bin/bash
# setup-wasm-target.sh — Install the wasm32-wasip1 Rust target (one-time setup).
# This is needed to compile Rust DSP scripts to WebAssembly.
set -euo pipefail

if rustup target list --installed | grep -q wasm32-wasip1; then
    echo "wasm32-wasip1 target already installed."
    exit 0
fi

echo "Installing wasm32-wasip1 target for Rust..."
rustup target add wasm32-wasip1
echo "Done. You can now compile Rust DSP scripts to WASM."
