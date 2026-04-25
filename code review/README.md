# Code review punch list

26 issues identified by an AI code review of the ConjureDSP repo. Each numbered file is a self-contained prompt to hand to another AI for review/action.

## Severity ordering (suggested)

**🔴 Server licensing — verified directly against source (act first):**
- 01 — token expiry never enforced
- 02 — no machine binding on /verify
- 03 — /activate is unauthenticated
- 04 — Paddle silent fallback poisons audit trail

**🟠 Server hardening — also verified:**
- 05 — CORS wildcard
- 06 — status codes leak existence
- 07 — webhook trusts event.data without re-querying

**🟠 Swift — line numbers approximate, verify before fixing:**
- 08 — render-lifecycle allocations (Combine/Sentry)
- 09 — `@unchecked Sendable` + unsynchronized param-metadata cache
- 10 — `try!` and force unwraps in production paths
- 11 — WebSocketServer weak-self gaps
- 12 — WebSocketServer un-upgraded-probe leak
- 13 — PTYManager strdup null-check
- 14 — PTYManager stop() re-entry / waitpid double-call
- 15 — PTYManager dispatch source replacement race
- 16 — fullState setter blocks main thread on script reload

**🟠 Rust — line numbers approximate, verify before fixing:**
- 17 — thread-local C-string returned across FFI (UAF hazard)
- 18 — WASM (ptr,len) decoded as UTF-8 without bounds clamp
- 19 — Vec allocations on the audio render path
- 20 — `Python::with_gil` in Drop / error paths
- 21 — ring buffer SPSC invariant unenforced
- 22 — hand-rolled ISO 8601 parser in license verifier
- 23 — `demo_fade_step` divides by sample_rate without validation

**🟡 Scripts — pure hygiene:**
- 24 — no checksums on bootstrapped toolchains (supply-chain)
- 25 — `set -e` without `set -u`
- 26 — `release.sh` rclone `|| true` swallows upload failures

## Notes for the next reviewer

- The 7 server findings were spot-checked against source and are real.
- The 16 Swift/Rust findings are from sub-agent reports; line numbers may be approximate. Each prompt asks the reviewer to verify the location before acting.
- One originally-reported issue (`preset_compressor.py` log10 order-of-operations) was a false positive (Python `/` binds tighter than `+`) and is excluded.
- The owner's stated preferences (per memory): surface real errors instead of guessing, prefer terse reporting, and prioritize functionality over binary size.
