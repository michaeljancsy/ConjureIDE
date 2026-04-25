An AI has found the following issue. Please review and assess whether action is needed.

# Server: /verify accepts machine_id but never validates it

## Context
ConjureDSP's licensing backend (`server/`) issues Ed25519-signed tokens. The `/activate` endpoint records a `machine_id` in an `activations` table when a transaction is first redeemed. The `/verify` endpoint is meant to refresh tokens for an already-activated install.

## Issue
`handleVerify` in `server/src/verify.ts` requires `machine_id` in the request body (and 400s if missing) but then never compares that value against any stored record. It looks up the subscription by ID extracted from the token payload, but does not check that the requesting `machine_id` is in the `activations` table for that subscription. The token itself also has no machine binding in its claims.

## Location
- `server/src/verify.ts` — entire handler, especially around lines 27–63
- `server/src/token.ts` — `createTokenPayload()` (no machine_id in claims)
- `server/schema.sql` — confirm `activations(subscription_id, machine_id, ...)` table exists

## Why it matters
A user can copy their token to another machine and refresh it indefinitely from there. There is no per-device limit and no way for the server to revoke a single device. Combined with the token-expiry-not-enforced bug, a leaked or shared token grants permanent access on unlimited devices.

## What to verify
- Read `server/src/verify.ts` and `server/src/token.ts` end to end.
- Inspect the `activations` table schema in `server/schema.sql` to see what's stored.
- Check whether the client (`SubscriptionManager.swift`) already sends a stable `machine_id` and whether it's ever rotated.

## Suggested approach
Two complementary changes:
1. In `handleVerify`, after looking up the subscription, also require that `(subscription_id, machine_id)` exists in `activations`. If not, 401.
2. Bind `machine_id` into the token payload (`TokenPayload`) so the client can also assert it locally. Reject at `verifyToken` if the token's `machine_id` differs from the one in the request.

Decide on a per-subscription device cap policy (e.g., 3 active machines) — without one, `/activate` will silently grow the activations table forever.
