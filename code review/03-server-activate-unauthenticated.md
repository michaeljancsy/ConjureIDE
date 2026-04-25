An AI has found the following issue. Please review and assess whether action is needed.

# Server: /activate accepts any transaction_id with no proof of ownership

## Context
ConjureDSP's `/activate` endpoint in `server/src/activate.ts` is called after a Paddle Billing checkout completes. The client posts `{ transaction_id, machine_id }`. The server resolves the transaction via the Paddle API, upserts the subscription into D1, and returns a signed token.

## Issue
The endpoint trusts whatever `transaction_id` the client sends. It does not verify that the requester actually owns the transaction — there is no logged-in user, no email proof, no shared secret from the Paddle return URL, no signed handoff from Paddle. Anyone who learns a `transaction_id` (Paddle confirmation emails, browser history, support tickets, screenshots, accidental sharing) can mint a token for that subscription on their own `machine_id`.

## Location
- `server/src/activate.ts` — `handleActivate()`, especially lines 12–104
- `server/src/index.ts` — route wiring (confirm there's no auth middleware in front)

## Why it matters
This is the primary licensing bypass. Combined with the missing machine binding on `/verify` and the lack of token expiry enforcement, a single leaked transaction_id is effectively a permanent license for whoever finds it. Paddle transaction IDs are not secrets — they appear in customer-facing flows.

## What to verify
- Read `server/src/activate.ts` and `server/src/index.ts` end to end. Confirm there is no auth check.
- Check what Paddle's checkout success flow returns to the client and whether any of it (e.g., a signed redirect, a customer auth token, a Passthrough field) could serve as proof of ownership.
- Check Paddle Billing docs for "validate transaction belongs to caller" patterns — Paddle supports passthrough data and customer portal tokens that could help.

## Suggested approach
Pick one of:
1. **Email-based proof**: After checkout, Paddle emails the customer; that email contains a one-time activation code that the app exchanges for a token. The transaction_id alone is no longer sufficient.
2. **Paddle Passthrough**: At checkout time, embed a per-session nonce in Paddle's `custom_data` / passthrough field, and require the client to present it alongside the transaction_id. Paddle echoes it back via the API, so the server can match.
3. **Paddle Customer Portal token**: Require the client to authenticate as the Paddle customer (signed JWT from Paddle) before token issuance.

Also enforce a per-transaction activation cap (e.g., one machine_id binding per `/activate` call, refuse re-activations on different machines without going through some recovery flow).
