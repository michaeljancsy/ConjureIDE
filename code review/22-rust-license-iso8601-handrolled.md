An AI has found the following issue. Please review and assess whether action is needed.

# Rust: hand-rolled ISO 8601 parser in license verifier

## Context
`rust/conjure_dsp/src/license.rs` verifies Ed25519-signed subscription tokens client-side. Tokens carry `valid_until` and `issued_at` fields as ISO 8601 strings; the verifier parses them to check expiry and grace-period status.

## Issue
The reviewer flagged (around lines 152–183) that `parse_iso8601_to_unix()` is a hand-rolled date parser with a comment admitting it's a "simple algorithm" valid only for the 2000–2099 range. Leap-year handling for edge cases (e.g., 2100 is *not* a leap year, but a naive `year % 4 == 0` check says it is) is not robustly verified, and the algorithm doesn't handle:
- Timezones other than `Z` / UTC (Paddle returns UTC, but only by convention)
- Fractional seconds
- Various ISO 8601 variants Paddle could conceivably emit

## Location
- `rust/conjure_dsp/src/license.rs` — `parse_iso8601_to_unix()` ~lines 152–183
- Token issuer for context: `server/src/token.ts` `createTokenPayload` (uses `toISOString()` which is well-defined)

## Why it matters
- Today: the server controls token format, so the parser only sees `YYYY-MM-DDTHH:MM:SS.sssZ` from `Date.prototype.toISOString()`. The hand-rolled parser likely handles this. So immediate impact is low.
- Tomorrow: any change in server behavior (e.g., switching to a different date library, adding a timezone offset, omitting fractional seconds) silently breaks license verification on the client. Users get locked out — or worse, locked in past expiry.
- The "valid 2000–2099" caveat means tokens issued in 2100 onward become un-parseable. Not urgent, but the kind of comment that ages badly.
- This is in `license.rs`, the most security-sensitive file in the Rust crate. It deserves a real parser.

## What to verify
- Read `parse_iso8601_to_unix()` end to end. Test it against:
  - `"2024-02-29T00:00:00.000Z"` (leap year)
  - `"2100-02-28T00:00:00.000Z"` (NOT a leap year — common bug)
  - `"2099-12-31T23:59:59.999Z"` (range edge)
  - `"2000-01-01T00:00:00Z"` (no fractional seconds)
- Check what format the server actually emits — `JSON.stringify(new Date())` always uses `.toISOString()` which is fixed.

## Suggested approach
- Replace with the `time` crate (lightweight, no_std-friendly, well-tested) using `time::OffsetDateTime::parse(s, &Rfc3339)`.
- Or `chrono` if already in the dep tree.
- Either adds ~50KB to the binary but eliminates a class of latent bugs in the most security-sensitive code path.
- If you want zero deps, fix the leap-year rule (`year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)`) and add unit tests for the edge cases above.
