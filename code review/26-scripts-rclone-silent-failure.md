An AI has found the following issue. Please review and assess whether action is needed.

# Scripts: release.sh swallows rclone upload failures with `|| true`

## Context
`scripts/release.sh` is the end-to-end release script. It builds, signs, notarizes, packages, and uploads to R2 (via `rclone`). The Sparkle appcast XML is also uploaded so existing installs see the new version.

## Issue
The reviewer flagged (around line 62) an `rclone copy ... || true` that suppresses every kind of failure: permission denied, network error, misconfigured remote, R2 outage. The script proceeds past the failure as if nothing happened.

## Location
- `scripts/release.sh` — `rclone copy` call ~line 62 (and possibly other `|| true` instances elsewhere in the script)

## Why it matters
- A failed upload of the appcast leaves the build out of sync: customers running older versions either see the old appcast (no update notification) or, worse, see a new appcast pointing at a build that didn't actually upload. Sparkle then 404s on download.
- `|| true` is sometimes legitimate (an idempotent cleanup command that's allowed to no-op), but for uploads it's almost always the wrong escape hatch.
- The owner has explicit prior feedback that "ship broken but quiet" is never acceptable; this is the same shape.

## What to verify
- Read `scripts/release.sh` end to end. Find every `|| true` and `2>/dev/null` and assess each one — they hide errors by design.
- Check whether the rclone command itself has `--dry-run` accidentally set, or whether `--retries` is configured.
- Trace the script's overall error semantics: does it exit non-zero if any step fails, and does that propagate to the GitHub Actions workflow (or whatever invokes it)?

## Suggested approach
- Remove `|| true` from upload commands. If the upload fails, the script should fail loudly.
- If there's a legitimate "upload may fail intermittently and we want to retry" need, use rclone's `--retries 3 --low-level-retries 5` rather than swallowing the result.
- If a specific failure mode genuinely should be tolerated (e.g., "appcast already up to date"), check for that exit code explicitly:
  ```bash
  rclone copy ... || rc=$?
  if [ "${rc:-0}" -ne 0 ] && [ "${rc:-0}" -ne <expected> ]; then
      echo "rclone failed: $rc" >&2
      exit "$rc"
  fi
  ```
- Add a final "verify appcast URL returns 200 and references the new version" check at the end of the script.
