# Activation Tracking (Soft Limit, No Enforcement)

## Context

Today, a Paddle transaction ID can be activated on unlimited machines. The server already records every activation in the `activations` table with `(subscription_id, machine_id, activated_at)`, but nothing is ever counted or enforced — no `COUNT(*)`, no `UNIQUE` constraint, no limit check. A single paid subscription = unlimited seats.

We need *some* seat-sharing policy before public launch, but we don't yet know whether sharing will be a real problem in practice. Rather than guessing at enforcement behavior (reject? auto-evict? in-app deactivate?) and risking locking out legitimate users mid-session, we're going to:

1. Publish a clear 2-machine-per-license policy in the UI
2. Make the existing activation tracking *actually reliable* (so the data is usable)
3. Ship a query we can run later to detect abuse
4. **Not enforce the limit yet** — revisit once we have data

This is a deliberate pre-launch choice. Pros:
- Zero friction for legit users (hardware upgrades, logic board swaps, DAW-sandbox machine-ID quirks, etc.)
- We'll know from real data whether sharing is actually happening before committing to a UX
- Cheap to ship now, cheap to upgrade later to real enforcement (same server endpoint)
- Better launch vibe — a plugin that locks you out during a mix gets 1-star reviews

Cons (acknowledged):
- If we later flip on enforcement and many users are over the limit, we have a communication problem. Mitigated by grandfathering existing activations at flip-time and/or announcing with lead time.

## Scope

This plan is tracking + UI copy only. **No enforcement logic. No new endpoints. No new client UI flows beyond copy.** When we decide to enforce later, that will be a separate plan.

## Changes

### 1. Schema: make activation tracking reliable

**File:** `server/src/schema.sql`

Add a `UNIQUE(subscription_id, machine_id)` constraint and a `last_seen_at` column to the `activations` table:

```sql
CREATE TABLE IF NOT EXISTS activations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  subscription_id TEXT NOT NULL,
  machine_id TEXT NOT NULL,
  activated_at TEXT NOT NULL,
  last_seen_at TEXT NOT NULL,
  FOREIGN KEY (subscription_id) REFERENCES subscriptions(id),
  UNIQUE (subscription_id, machine_id)
);
```

Write a migration SQL file (`server/migrations/0002_activations_unique_and_last_seen.sql` or whatever the existing convention is — check `server/migrations/` or the wrangler config) that:
- Adds `last_seen_at` column (default `activated_at` for existing rows, though pre-release there are none)
- Deduplicates any existing `(subscription_id, machine_id)` rows (keep earliest `activated_at`)
- Adds the UNIQUE constraint

### 2. `/activate`: make repeated activations idempotent + set `last_seen_at`

**File:** `server/src/activate.ts` (around lines 76–81, the existing `INSERT INTO activations` statement)

Change the insert to an upsert:

```typescript
await env.DB.prepare(
  `INSERT INTO activations (subscription_id, machine_id, activated_at, last_seen_at)
   VALUES (?, ?, datetime('now'), datetime('now'))
   ON CONFLICT(subscription_id, machine_id)
   DO UPDATE SET last_seen_at = datetime('now')`
).bind(subscriptionId, body.machine_id).run();
```

This way, a user reinstalling or re-activating the same machine doesn't inflate the count. Each row represents one distinct machine.

### 3. `/verify`: update `last_seen_at` on every token refresh

**File:** `server/src/verify.ts` (lines 11–73)

After looking up the subscription and before returning the fresh token, update the matching activation row:

```typescript
await env.DB.prepare(
  `UPDATE activations
   SET last_seen_at = datetime('now')
   WHERE subscription_id = ? AND machine_id = ?`
).bind(subscriptionId, body.machine_id).run();
```

This gives us a meaningful "machines active in the last 30 days" number rather than just "machines that ever activated." A machine that activated once and never verified again is almost certainly a wipe/reinstall, not a real seat.

Note: if the `machine_id` isn't in `activations` yet (e.g., a client that somehow got a token without going through `/activate`), the UPDATE is a no-op. Don't `INSERT` from `/verify` — that would create untracked activations and defeat the tracking.

### 4. Fix the `IOPlatformUUID` fallback before launch

**File:** `ConjureDSPExtension/Model/SubscriptionAPI.swift` (lines 103–116, `static func machineID()`)

Current code falls back to `UUID().uuidString` if `IOPlatformUUID` isn't readable. If that fallback ever triggers in production (e.g., in a DAW sandbox that blocks IOKit), every app launch generates a new machine ID and our tracking data becomes meaningless.

Required changes:
- **First:** investigate whether the fallback actually triggers. Build Debug, run in Logic, Ableton, and GarageBand, log whether `IOServiceGetMatchingService(kIOMainPortDefault, ...)` succeeds from inside the AU extension process. If IOKit works everywhere, no code change needed — just add a `// verified reachable from AU sandbox` comment.
- **If IOKit is blocked in any DAW:** change the fallback to a persistent UUID stored in the App Group container (`group.com.MichaelJancsy.ConjureDSP`) — generate once on first miss, write to `machine_id.txt`, read thereafter. This survives reinstalls of the AU extension because the App Group container is owned by the host app / terminal helper, not the extension. Still leaky (container wipe → new ID) but vastly better than "new ID every launch."
- **Never** fall back to an unpersisted random UUID — remove that branch.

### 5. UI copy: publish the 2-machine policy

Add "2 machines per license" text to two places in the host app:

- **Activation view** — wherever the user enters their transaction ID. One line under the input: "Each license activates up to 2 machines." Find this view by searching for `SubscriptionAPI.activate` call sites in the host app target.
- **Subscription settings / status view** — wherever the user sees their current subscription status. Display something like "Activated on this Mac • 2 machines allowed per license." Find this by searching for `SubscriptionManager` property accesses in SwiftUI views.

This is purely a text change (no new UI components). The UI states the policy; the server quietly logs reality.

### 6. Abuse monitoring query

**New file:** `server/scripts/abuse-query.sql`

```sql
-- Run periodically (e.g., monthly) to check for shared/over-limit activations.
-- Thresholds are soft (no enforcement) — this is a monitoring tool only.

SELECT
  s.id AS subscription_id,
  s.email,
  s.status,
  COUNT(DISTINCT a.machine_id) AS total_machines,
  COUNT(DISTINCT CASE
    WHEN a.last_seen_at > datetime('now', '-30 days')
    THEN a.machine_id
  END) AS active_machines_30d,
  MIN(a.activated_at) AS first_activation,
  MAX(a.last_seen_at) AS most_recent_activity
FROM subscriptions s
LEFT JOIN activations a ON a.subscription_id = s.id
GROUP BY s.id
HAVING total_machines > 2
ORDER BY active_machines_30d DESC, total_machines DESC;
```

The `active_machines_30d` column is the one that matters for deciding whether to enforce. A subscription with `total_machines = 10` but `active_machines_30d = 2` is a user who has upgraded hardware a few times — not abuse. A subscription with `active_machines_30d = 8` is a real sharer.

Also add a short `README.md` next to the query (or a comment block in `server/README.md`) explaining how to run it against the production D1 database via `wrangler d1 execute`.

## Files to modify

- `server/src/schema.sql` — add `last_seen_at`, add UNIQUE constraint
- `server/migrations/<next>_activations_unique_and_last_seen.sql` — new migration file (match existing convention)
- `server/src/activate.ts` — upsert instead of insert (lines 76–81)
- `server/src/verify.ts` — UPDATE `last_seen_at` on verify
- `ConjureDSPExtension/Model/SubscriptionAPI.swift` — fix `machineID()` fallback (lines 103–116)
- Host app activation view — copy addition
- Host app subscription status view — copy addition
- `server/scripts/abuse-query.sql` — new file
- `server/README.md` or similar — add a note on how to run the abuse query

## Explicitly out of scope

- Any rejection logic in `/activate`
- Any `/deactivate` or `/machines` endpoints
- Any in-app "manage activations" UI
- Any client-side enforcement
- Any changes to token format or the Rust license verification
- Any changes to the grace period, demo mode, or `SubscriptionStatus` enum

When we decide to enforce (if we do), that will be a separate plan that builds on this one.

## Verification

1. **Migration runs cleanly**
   - Apply the migration locally: `cd server && wrangler d1 migrations apply conjuredsp-db --local`
   - Confirm `activations` table has `last_seen_at` column and UNIQUE index via `wrangler d1 execute conjuredsp-db --local --command ".schema activations"`

2. **Upsert behavior**
   - Hit `/activate` twice with the same transaction ID + machine ID. Expect one row, not two. `SELECT COUNT(*) FROM activations WHERE subscription_id = ?` returns 1.
   - Hit `/activate` with the same transaction ID but different machine IDs. Expect N rows for N distinct machines.
   - Confirm `last_seen_at` updates on the second call (compare to `activated_at`).

3. **`/verify` touches `last_seen_at`**
   - After activating, wait a few seconds, hit `/verify` once, confirm `last_seen_at > activated_at` for that row.
   - `/verify` with an unknown `machine_id` should succeed (token still returned) but not create a row.

4. **Machine ID stability**
   - Build Debug and run in the host app. Note the `machine_id` printed in the request body (add a temporary `print` in `SubscriptionAPI.activate` for testing).
   - Restart the app. Confirm the `machine_id` is identical.
   - Load the AU in Logic Pro, Ableton Live, and GarageBand. Confirm `machine_id` is identical across all of them and matches the host app.
   - If any DAW produces a different ID: the fallback is triggering and the persistence fix is required before shipping.

5. **UI copy is visible**
   - In the activation view, confirm the "2 machines per license" line is visible and correctly placed.
   - In the subscription settings view, confirm the limit is displayed.

6. **Abuse query runs**
   - `wrangler d1 execute conjuredsp-db --remote --file server/scripts/abuse-query.sql` (or local equivalent)
   - Confirm it returns sensibly (likely 0 rows in staging).

7. **No regressions**
   - Existing subscription tests still pass: `cd server && npm test` (or whatever the server test command is)
   - Swift tests still pass: `xcodebuild -project ConjureDSP.xcodeproj -scheme ConjureDSP test -only-testing:ConjureDSPTests`
   - Full activation → verify → refresh loop still works end-to-end with a real Paddle sandbox transaction.

## Key design files (reference)

- `server/src/activate.ts:12-101` — activation endpoint
- `server/src/verify.ts:11-73` — verify/refresh endpoint
- `server/src/schema.sql` — D1 schema
- `server/src/token.ts:1-112` — Ed25519 token signing
- `server/src/webhook.ts:16-92` — Paddle webhook handler (unchanged by this plan)
- `ConjureDSPExtension/Model/SubscriptionAPI.swift:37-117` — HTTP client
- `ConjureDSPExtension/Model/SubscriptionManager.swift:40-253` — token lifecycle
- `rust/conjure_dsp/src/license.rs:106-245` — Rust-side token verification (unchanged by this plan)
