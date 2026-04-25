An AI has found the following issue. Please review and assess whether action is needed.

# Server: distinct status codes leak subscription/transaction existence

## Context
ConjureDSP's licensing endpoints return different HTTP status codes for different failure modes — 401 for "invalid token", 404 for "subscription not found", 400 for "transaction has no subscription", etc.

## Issue
`/verify` returns 401 when the token signature is invalid but 404 when the token is valid and the subscription row is missing. `/activate` distinguishes "transaction not found" (404) from "transaction has no subscription" (400). These distinctions let an unauthenticated caller enumerate which subscription IDs exist in the database, and which Paddle transaction IDs are recognized.

## Location
- `server/src/verify.ts` — lines 30–34 (401 for invalid token) vs lines 49–54 (404 for missing subscription)
- `server/src/activate.ts` — lines 31–43 (404 vs 400 distinctions)

## Why it matters
Combined with the missing auth on `/activate`, an attacker can enumerate transaction IDs (which have a constrained format) by observing which return 404 vs 400 vs 200. Subscription IDs likewise. This makes the existing `/activate` weakness easier to exploit at scale.

The severity is moderate — it's a confidentiality/enumeration issue, not direct compromise. But it's cheap to fix.

## What to verify
- Read both handler files end to end.
- Check the format of Paddle transaction IDs and subscription IDs (length, character set, prefix). The narrower the format, the more practical brute enumeration becomes.

## Suggested approach
Collapse all token-or-subscription failure modes on `/verify` to a single response (e.g., 401 with `{ error: "Invalid token" }`). On `/activate`, return a single generic error for any "we cannot issue a token for this transaction" case (signature/existence/state). Pair with rate limiting (per-IP, per-transaction-prefix) to make enumeration costlier.

Do not over-collapse: log the real failure reason server-side (sanitized) so debugging remains feasible.
