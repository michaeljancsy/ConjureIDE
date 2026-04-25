An AI has found the following issue. Please review and assess whether action is needed.

# Server: token expiry never enforced server-side

## Context
ConjureDSP is an AUv3 audio plugin with a Cloudflare Workers backend that issues Ed25519-signed subscription tokens. Tokens carry a `valid_until` claim. The client checks expiry locally, but the server is supposed to be the authoritative gate when `/verify` is called to refresh a token.

## Issue
`verifyToken()` in `server/src/token.ts` validates the Ed25519 signature and parses the JSON payload, but never compares `payload.valid_until` against the current time. As a result, any token that was ever validly signed can be presented to `/verify` indefinitely, and the server will happily mint a fresh token for it — regardless of whether the original token's `valid_until` has long passed, or whether the underlying subscription is still active at signing time vs. now.

## Location
- `server/src/token.ts` — `verifyToken()` (around lines 73–94)
- `server/src/verify.ts` — call site that consumes the result and never checks expiry either

## Why it matters
This neutralizes the entire token expiry mechanism on the server. A user who cancels their subscription and keeps an old token around can refresh forever (the refresh re-reads DB status, but if the DB row says "active" at refresh time, that's irrelevant — the issue is that the server never refuses to *talk* to an expired token). More importantly, if a token leaks (e.g., copied from a friend), it can be refreshed without time bound.

## What to verify
- Confirm `verifyToken()` truly does not check `valid_until`. Read the file end-to-end.
- Check whether `handleVerify` in `server/src/verify.ts` does the check itself (it doesn't, per the AI's review, but verify).
- Check whether the client-only check is acceptable for the threat model the owner has in mind. It probably isn't — server-side enforcement is the whole point of `/verify`.

## Suggested approach
Add an expiry check inside `verifyToken()` (or in `handleVerify`) that returns null/401 when `Date.now() > Date.parse(payload.valid_until)`. Consider also rejecting tokens whose `issued_at` is implausibly old, to defend against tokens minted before a key rotation. Be aware the `valid_until` already has a 24h clock-skew buffer added at signing time in `createTokenPayload()` — don't double-buffer.
