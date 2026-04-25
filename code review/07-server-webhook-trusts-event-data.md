An AI has found the following issue. Please review and assess whether action is needed.

# Server: webhook trusts event.data fields without re-querying Paddle

## Context
`server/src/webhook.ts` receives Paddle Billing webhooks (subscription.created/updated/canceled, etc.). It verifies the webhook signature first, then uses fields from the event body to update D1.

## Issue
After signature verification passes, the handler reads `event.data.id`, `event.data.status`, `event.data.current_billing_period`, etc. directly and writes them to D1. The signature proves Paddle (or whoever has the webhook secret) sent *this exact body* — but it does not re-confirm the body's accuracy at write time. If the webhook secret ever leaks, an attacker can forge bodies that flip subscriptions to `active` indefinitely. There is also no replay protection: the same webhook body can be re-sent and re-processed.

## Location
- `server/src/webhook.ts` — entire `handleSubscriptionEvent()` and surrounding handlers

## Why it matters
- **Webhook secret rotation hygiene**: if the secret is in the same env as the Ed25519 signing key (likely), a single secret leak compromises both. Re-querying Paddle by ID with the API key forces an attacker to compromise *both* secrets.
- **Replay**: there is no `event_id` deduplication store. An attacker (or a buggy upstream retry) can re-deliver an old "active" event after a real cancellation and revert the DB.

## What to verify
- Read `server/src/webhook.ts` and the schema (`server/schema.sql`) — confirm there's no `processed_events` table or unique constraint on event_id.
- Check Paddle Billing's webhook docs for the recommended replay-protection pattern (event ID deduplication is standard).
- Inspect what `verifyPaddleSignature` actually checks (timestamp window? body hash only?).

## Suggested approach
1. **Deduplicate**: add a `processed_events(event_id PRIMARY KEY, processed_at)` table. Refuse to process an event whose ID has been seen.
2. **Re-query for high-stakes transitions**: on subscription cancel/expire/active flips, re-fetch the subscription from Paddle's API by ID before writing. The signature gives you authentication of the trigger; the API call gives you the current truth.
3. **Timestamp window**: ensure signature verification rejects events older than ~5 minutes (Paddle typically signs over a timestamp).
