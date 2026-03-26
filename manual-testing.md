# Manual Testing Checklist

Incomplete test items from open PRs. Check off as you verify each item.

## PR #81 — [Add Sparkle auto-update framework](https://github.com/michaeljancsy/conjuredsp-application/pull/81)

- [ ] Launch app and verify "Check for Updates…" appears in the app menu
- [ ] After configuring feed URL + EdDSA key, test full update flow per the integration plan

## PR #78 — [Replace license keys with Paddle Billing subscriptions](https://github.com/michaeljancsy/conjuredsp-application/pull/78)

- [ ] Manual: deploy server to Cloudflare staging, test Paddle sandbox checkout → activation → token refresh → grace period → demo fallback
