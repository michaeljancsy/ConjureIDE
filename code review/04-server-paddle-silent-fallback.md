An AI has found the following issue. Please review and assess whether action is needed.

# Server: Paddle API failures silently produce empty-string emails

## Context
During `/activate`, the Cloudflare Worker calls Paddle's API to resolve a transaction → subscription → customer email, then upserts a row into D1 and signs a token.

## Issue
`fetchPaddleCustomerEmail()` in `server/src/activate.ts` returns the empty string `""` on any non-OK response from Paddle (404, 500, 401, network error). The caller does not distinguish "Paddle is down / returned 5xx" from "customer truly has no email" and proceeds to upsert the subscription with `email = ""` and sign a token. The same loose error handling exists for `fetchPaddleTransaction` and `fetchPaddleSubscription`, which return `null` on any failure and produce a generic 404 to the client.

## Location
- `server/src/activate.ts` — `fetchPaddleCustomerEmail()` around lines 159–175, plus `fetchPaddleTransaction` and `fetchPaddleSubscription` (~lines 123–157), and the upsert at lines 59–76

## Why it matters
- **Audit trail is poisoned**: subscriptions can land in D1 with empty emails when Paddle was just temporarily down. Customer support and account-recovery flows now have nothing to look up by.
- **Retry behavior is wrong**: a transient Paddle 503 surfaces to the user as "Transaction not found" (404) — they will assume their purchase failed and may either contact support or re-purchase.
- **Status drift**: the upsert uses `sub.status` from Paddle. If that fetch silently degrades or returns stale data, the token gets signed with a status that doesn't reflect reality.

## What to verify
- Read `server/src/activate.ts` end to end.
- Check whether the webhook handler (`server/src/webhook.ts`) eventually corrects the email on subscription updates — if so, the empty-email window is bounded; if not, it persists forever.
- Check whether D1 has any `NOT NULL` constraint on `email` (`server/schema.sql`).

## Suggested approach
Distinguish "Paddle says no" (404 from Paddle on a real lookup) from "Paddle is unavailable" (5xx, network error, timeout). On the latter, return 503 to the client so it can retry, and do not upsert. On the former, decide whether to upsert with a sentinel value or refuse activation entirely. Consider adding a `NOT NULL` constraint on `subscriptions.email` to make this fail loudly rather than silently. Log the underlying Paddle error (without leaking the API key) for observability.
