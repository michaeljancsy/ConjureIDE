An AI has found the following issue. Please review and assess whether action is needed.

# Scripts: setup scripts download toolchains over the network with no integrity check

## Context
ConjureDSP bootstraps several toolchains at first build via shell scripts: a free-threaded Python 3.14 distribution, the Rust compiler with a `wasm32-wasip1` sysroot, the `uv` package manager, the Monaco editor, and xterm.js. Each is fetched via `curl` and unpacked. Some of the downloaded artifacts are then *embedded into the shipping app* (`rustc-dist`, `python-dist`).

## Issue
None of the setup scripts verify the integrity of what they download. There are no `sha256sum -c` checks, no GPG signatures, no pinned version digests. A compromised mirror, a CDN cache poisoning, a BGP hijack, or a future supply-chain compromise of the upstream (python-build-standalone, rust-lang.org, GitHub releases for `uv` / Monaco / xterm.js) silently injects code into both the developer's machine *and* the binaries that ship to customers.

## Location
- `rust/setup-python.sh` — downloads python-build-standalone tarball
- `scripts/setup-rustc.sh` — downloads standalone rustc + cargo + wasm sysroot
- `scripts/setup-monaco.sh` — downloads Monaco editor
- `scripts/setup-xterm.sh` — downloads xterm.js
- `scripts/setup-uv.sh` — downloads `uv` binary

## Why it matters
- The Rust compiler and Python runtime are bundled into the shipping app. A compromised binary at setup time → every customer gets a backdoored plugin. The app is signed and notarized, but signing wraps whatever bytes are present.
- The blast radius is the entire customer base. The cost of fixing is small (compute and pin a SHA256 once per dependency version).
- This is the kind of supply-chain hygiene that's a known industry-standard expectation for any project that ships embedded runtimes.

## What to verify
- Read each setup script to confirm the absence of integrity checks.
- For each, identify the download URL and check whether the upstream publishes signed checksums (most do).
- Check whether `xcodebuild` setup invokes these scripts on every build or only first-run.

## Suggested approach
- For each setup script, add a `EXPECTED_SHA256="..."` constant near the URL. After download, run `shasum -a 256 -c <(echo "$EXPECTED_SHA256  $file")` and exit non-zero on mismatch.
- For `python-build-standalone`, they publish SHA256 sums alongside releases — fetch and verify the sums file too (or pin the sums file's hash).
- For `rust-lang.org` Rust toolchains, the dist server publishes `.sha256` siblings to every artifact.
- Document the upgrade procedure: bump version, recompute hash, commit both together.
- Consider also checking that the unpacked tarball's expected top-level files exist (defense in depth — a malicious tarball with the right hash is still possible if the dev environment's `shasum` is itself compromised, but that's a different threat model).
