An AI has found the following issue. Please review and assess whether action is needed.

# Scripts: bash scripts use `set -e` without `set -u`

## Context
ConjureDSP's build, release, and setup scripts are written in bash. Most start with `set -e` to fail fast on command errors.

## Issue
The reviewer flagged that several scripts use `set -e` but not `set -u` (or `set -euo pipefail`). Without `set -u`, a typo in a variable name silently becomes the empty string. This combines disastrously with patterns like:
```bash
rm -rf "$BUILD_DIR"/*    # if BUILD_DIR is unset, this is rm -rf /*
cd "$OUTPUT_DIR" && ...  # silently cd to $HOME, runs commands there
cp "$ARTIFACT" "$DEST"   # copies "" to "" — no-op, no error
```

The reviewer specifically called out `scripts/pre-build-clean.sh` as an example, but the pattern likely repeats across the script directory.

## Location
- `scripts/pre-build-clean.sh` — flagged at line 2
- Sweep needed: `head -3 scripts/*.sh rust/*.sh` to see which ones lack `set -u`

## Why it matters
- The empty-variable + `rm -rf` failure mode is catastrophic: it can wipe a developer's home directory or `/Applications`. It's a well-known bash footgun and the standard mitigation is one-line.
- For release scripts (`release.sh`, `notarize.sh`, `create-dmg.sh`), an unset variable mid-flow can produce a silently broken artifact that still gets uploaded.
- `set -u` catches this at runtime with a clear error message.

## What to verify
- List all `.sh` files: `find . -name "*.sh" -not -path "./.git/*"`.
- For each, check the shebang line and the first few lines for `set -e`, `set -u`, `set -o pipefail`.
- Identify scripts that perform destructive operations (`rm -rf`, `find -delete`, `cp -R`) — these are the highest priority.

## Suggested approach
- Standardize the script header to:
  ```bash
  #!/usr/bin/env bash
  set -euo pipefail
  IFS=$'\n\t'
  ```
- For variables that are intentionally optional, use `${VAR:-default}` to express that explicitly.
- Run shellcheck on the whole `scripts/` directory and address the warnings; many will overlap with this issue.
- Audit every `rm -rf "$VAR"` in the codebase for the empty-variable case; consider replacing with `rm -rf "${VAR:?VAR must be set}"/...`.
