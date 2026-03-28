# Manual Testing Checklist

Incomplete test items from open PRs. Check off as you verify each item.

## PR #90 — [Add ETag caching, retry/backoff, and tests to GitHub integration](https://github.com/michaeljancsy/conjuredsp-application/pull/90)

- [ ] Open community browser, verify presets load; reload and check console for ETag cache hits
- [ ] Verify no regressions in personal repo sync flow

## PR #88 — [Add Monaco inline error markers and custom color themes](https://github.com/michaeljancsy/conjuredsp-application/pull/88)

- [ ] Write a Python script with a syntax error — verify red squiggly appears on the correct line
- [ ] Write a Rust script with a type error — verify marker on correct line
- [ ] Fix the error and re-run — verify markers clear
- [ ] Switch between all 9 theme options in Settings — verify colors apply
- [ ] Set "Auto (System)" and toggle macOS dark/light mode — verify theme follows
- [ ] Restart the plugin — verify theme preference persists

## PR #87 — [Add real-time process function profiler](https://github.com/michaeljancsy/conjuredsp-application/pull/87)

- [ ] Manual: load a DSP script, play audio, verify status bar shows live updating timing
- [ ] Manual: load a heavy script, verify peak/avg reflect higher processing time
- [ ] Manual: bypass, verify profiler stops updating

## PR #86 — [Add conjuredsp Rust library and migrate factory presets](https://github.com/michaeljancsy/conjuredsp-application/pull/86)

- [ ] Manual: open app, load factory Rust presets, verify audio output
- [ ] Manual: create new Rust script from template, verify it compiles and runs

## PR #81 — [Add Sparkle auto-update framework](https://github.com/michaeljancsy/conjuredsp-application/pull/81)

- [ ] Launch app and verify "Check for Updates…" appears in the app menu
- [ ] After configuring feed URL + EdDSA key, test full update flow per the integration plan

## PR #78 — [Replace license keys with Paddle Billing subscriptions](https://github.com/michaeljancsy/conjuredsp-application/pull/78)

- [ ] Manual: deploy server to Cloudflare staging, test Paddle sandbox checkout → activation → token refresh → grace period → demo fallback
