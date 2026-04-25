An AI has found the following issue. Please review and assess whether action is needed.

# Server: CORS Access-Control-Allow-Origin: *

## Context
The Cloudflare Workers backend (`server/`) handles activation, verification, and webhook traffic for ConjureDSP licensing.

## Issue
The CORS middleware in `server/src/index.ts` sets `Access-Control-Allow-Origin: *` on responses. The endpoints accept POST bodies containing `transaction_id` / `token` / `machine_id`. Currently the app uses a native HTTP client (no browser, no cookies), so CORS is mostly irrelevant — but the wildcard configuration means any web page on any origin can call these endpoints from a victim's browser.

## Location
- `server/src/index.ts` — around line 12 (CORS header wiring)

## Why it matters
Today, the impact is low because the API doesn't use browser auth state (no cookies, no `credentials: include`). However:
- If a future "manage subscription" web UI is added on `conjuredsp.com` and it sets cookies, `Allow-Origin: *` cannot be combined with `Allow-Credentials: true` (browsers refuse), but more importantly any other origin could still hit the same endpoints — and a CSRF on a cookie-bearing endpoint becomes possible.
- It's a lurking footgun: someone will eventually add `credentials: include` to a fetch and assume CORS is hardened.

## What to verify
- Read `server/src/index.ts` to see the exact CORS configuration.
- Check whether any endpoint relies on browser auth state (cookies, Basic auth) — currently it should not.
- Confirm whether there's a planned web UI that will need cross-origin POSTs.

## Suggested approach
Restrict `Access-Control-Allow-Origin` to a known set: the production web origin (if one exists), `null` for native clients (which don't send Origin), or simply omit CORS headers entirely for endpoints that are only called by the native app. Native HTTP clients do not need CORS — only browsers enforce it. If you intend to keep the API browser-callable from a specific site, hard-code that origin and respond per-request based on the request's `Origin` header.
