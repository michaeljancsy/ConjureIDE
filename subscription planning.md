# Architecture Exploration: Subscription Model via Paddle Billing

## Context

ConjureDSP currently uses offline Ed25519 permanent license keys with a 60-second per-session demo. The goal is to switch to a Paddle Billing subscription model before any licenses have been sold. This document explores the architecture, trade-offs, and key decisions involved.

## Current System

- **Verification**: Fully offline. Ed25519 signature checked against embedded public key.
- **Storage**: Serial string at `~/Library/Application Support/ConjureDSP/license.key`
- **Audio thread**: `AtomicBool` licensed flag — lock-free, no blocking.
- **Demo**: 60s of non-silent output per session, then silence. Restartable.
- **No server component** — everything is local.

## Proposed Architecture

### High-Level Flow

```
┌─────────────┐     ┌──────────────┐     ┌─────────────┐
│  macOS App   │────▶│  Your Server │◀────│   Paddle    │
│  (AU plugin) │◀────│  (API + DB)  │     │  (Billing)  │
└─────────────┘     └──────────────┘     └─────────────┘
       │                                        │
       └──── Paddle Mac SDK checkout ───────────┘
```

**New requirement**: A backend server. This is the biggest architectural change — subscriptions cannot work purely offline.

### Component Breakdown

#### 1. Backend Server (NEW)

A lightweight API server that:
- **Receives Paddle webhooks** (`subscription.created`, `subscription.canceled`, `transaction.completed`, etc.)
- **Validates webhook signatures** (HMAC)
- **Issues signed subscription tokens** to the app (time-limited, like JWTs)
- **Stores** subscription → user mapping in a database

**Endpoints:**
- `POST /webhooks/paddle` — Paddle webhook receiver
- `POST /verify` — App sends its token, server returns current subscription status + fresh signed token
- `POST /activate` — After checkout, app sends Paddle transaction ID, server returns initial token

**Token format** (signed by server's Ed25519 key, reusing existing crypto):
```json
{
  "email": "user@example.com",
  "subscription_id": "sub_abc123",
  "status": "active",
  "valid_until": "2026-04-01T00:00:00Z",  // e.g., 7 days from issuance
  "issued_at": "2026-03-25T00:00:00Z"
}
```

This lets the app verify tokens offline using the embedded public key (same Ed25519 scheme as today), while the `valid_until` field enforces periodic re-verification.

#### 2. macOS App Changes

**Checkout flow:**
- Paddle Mac SDK V4 handles native checkout UI
- On successful purchase → app calls server `/activate` with transaction ID
- Server returns signed token → app stores it locally

**Verification flow (on every launch + periodic):**
1. Load cached token from disk
2. Check `valid_until` — if still valid, accept it (offline OK)
3. If expired or missing, call server `/verify` to get a fresh token
4. If server unreachable and token expired < grace period (e.g., 7 days past `valid_until`), allow access with UI warning
5. If server unreachable and beyond grace period → demo mode

**What stays the same:**
- `AtomicBool` licensed flag on audio thread — unchanged
- Demo mode (60s silence) — unchanged, used as fallback
- `LicenseManager` orchestrates everything — same role, different verification logic
- License file location — same path, different content (token instead of serial)

**What changes:**
- `license.rs` verification: check token signature + `valid_until` instead of just signature
- `LicenseManager.swift`: adds periodic re-verification timer, server communication, grace period logic
- UI: subscription status (active, grace period, expired) instead of binary licensed/unlicensed
- New: "Manage Subscription" button that opens Paddle customer portal

#### 3. Paddle Integration

- **Paddle Mac SDK V4** for native checkout (sheet/window in the app)
- **Paddle Billing** (not Classic) for subscription management
- **Webhook events** to track: `subscription.created`, `subscription.canceled`, `subscription.past_due`, `subscription.updated`, `transaction.completed`

### Grace Period Design

```
Token valid_until
       │
       ▼
  ─────┼──────────────────┼─────────────────▶ time
       │   Grace Period    │
       │   (7 days)        │
       │                   │
   App tries to verify     If still offline,
   Shows "offline" warning  → demo mode
   Full access continues
```

- Grace period = 7 days past `valid_until`
- During grace: full access, but UI shows "Subscription verification pending — connect to internet"
- After grace: falls back to demo mode (existing 60s behavior)
- On successful re-verification: grace resets, warning clears

### Key Design Decisions

#### A. Token vs License Key

**Recommended: Signed time-limited tokens** (not Paddle license keys)

Why: Paddle Billing doesn't have built-in license key generation like Classic did. Rather than using a third-party licensing service (Keygen), issue your own signed tokens from your server. This reuses the existing Ed25519 infrastructure and keeps the offline verification path simple.

#### B. Server Technology

Options:
- **Cloudflare Workers + D1** — serverless, cheap, low maintenance, SQLite-based
- **Fly.io + SQLite** — simple deployment, persistent storage
- **AWS Lambda + DynamoDB** — scalable but more complex
- **Simple VPS (Hetzner/DigitalOcean) + SQLite** — full control, cheap

Recommendation: **Cloudflare Workers + D1** or **Fly.io** — both are low-maintenance and cheap for the expected traffic volume (license checks, not high-throughput).

#### C. What Happens to the Existing Ed25519 System

Two options:
1. **Replace entirely** — tokens use a new format, old serials stop working
2. **Extend** — tokens are a superset of the old format, server signs them with the same key

Recommendation: **Replace** since there are no existing users. Simplifies the code — no need to support two formats.

#### D. Subscription Tiers

Consider whether you need tiers now or later:
- **Single tier** — simplest, one price, full access
- **Multiple tiers** — e.g., basic (Python only) vs pro (Python + Rust/WASM + export)

Recommendation: **Start with a single tier.** Can add tiers later by including a `tier` field in the token.

### Migration Path from Current Code

| Component | Current | Subscription |
|-----------|---------|-------------|
| `license.rs` | Verify Ed25519 serial | Verify Ed25519 token + check `valid_until` |
| `kernel.rs` | `AtomicBool` licensed | Same — no change |
| `lib.rs` FFI | `verify_license(serial)` | `verify_token(token_json)` — returns status enum |
| `LicenseManager.swift` | Load file, verify once | Load token, verify periodically, call server |
| `LicenseSettingsView.swift` | Serial text field | "Subscribe" button + status display |
| Demo mode | 60s per session | Same — fallback when token expired + offline |
| Server | None | New lightweight API |

### Risks and Considerations

1. **Server is a single point of failure** — if your server goes down, users in grace period are fine, but new activations fail. Mitigation: use a reliable host + uptime monitoring.

2. **Latency for studio musicians** — verification should be non-blocking. Never delay audio processing for a network call. The `AtomicBool` approach already handles this correctly.

3. **Piracy surface changes** — permanent keys can be shared forever; tokens expire. Subscriptions are inherently more piracy-resistant since tokens need periodic refresh.

4. **User experience** — subscription fatigue is real for creative tools. Consider offering annual pricing at a discount to reduce friction.

5. **App Store considerations** — if you ever distribute via Mac App Store, Apple requires using their IAP for subscriptions. Paddle works for direct distribution only.

6. **Token clock skew** — users with incorrect system clocks could have issues with `valid_until` checks. Use generous margins (hours, not minutes).

### What You'd Need to Build

1. **Backend server** — ~200-400 lines of code (webhook handler, verify endpoint, token signing, DB schema)
2. **Rust token verification** — modify `license.rs` to parse token JSON + check expiry (~50 lines changed)
3. **Swift subscription manager** — refactor `LicenseManager.swift` for periodic verification + server calls (~200 lines changed)
4. **UI updates** — subscription status, manage subscription link, remove serial input (~100 lines changed)
5. **Paddle Mac SDK integration** — checkout flow in Swift (~100 lines new)
6. **Paddle dashboard setup** — product, pricing, webhook configuration (no code)

### Open Questions

- Monthly, annual, or both pricing?
- Free trial duration? (Currently 60s demo — could offer a 7-day or 14-day full trial instead)
- Should the server also handle crash reports / analytics, or keep those separate (Sentry/Mixpanel)?
