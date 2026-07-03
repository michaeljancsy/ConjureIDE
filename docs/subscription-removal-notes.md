# Subscription / demo / beta removal — what was removed and how to restore it

ConjureDSP was made **completely free**: the Paddle-billing subscription, the
60-second demo gate, the 30-day beta window, and the export-requires-license
lock were all removed. This doc records exactly what changed so a future
maintainer can bring the paywall back if desired.

**The whole change is one commit on branch `claude/nice-bouman-b5bb8f`, branched
off `main` at `0cb82d7`.** The complete prior implementation is recoverable with
`git revert <removal-sha>` or by reading the pre-change files at
`git show 0cb82d7:<path>`. Nothing was lost — this is a delete, not a rewrite.

## What still works (do NOT touch when restoring)

- **App auto-updates.** Entirely separate from the subscription server. Handled
  by **Sparkle 2.x** pulling `appcast.xml` + DMGs from the Cloudflare **R2**
  bucket `conjuredsp-updates` at `updates.conjuredsp.com`. Driven by
  `ConjureDSP/ConjureDSPApp.swift`, `Info.plist`'s `SUFeedURL`, and
  `scripts/build.sh` / `scripts/release.sh`. The subscription server never had
  any update role.

## Code that was removed (restore = revert the commit)

Rust (`rust/conjure_dsp/src/`):
- Deleted `license.rs` (Ed25519 verify, `SubscriptionStatus`, grace period,
  embedded XOR-masked public key).
- `kernel.rs`: removed the `licensed` flag, demo counters/fade
  (`demo_samples_processed`, `demo_limit_samples`, `demo_gain`,
  `demo_fade_step`), the `DEMO_*` constants, the render-path demo gate, and the
  `set_licensed` / `is_licensed` / `demo_seconds_remaining` / `reset_demo` /
  `set_subscription_status` / grace-deadline methods, plus `buffer_peak`.
- `lib.rs`: removed 9 FFI exports (`dsp_kernel_verify_token`,
  `dsp_kernel_is_licensed`, `dsp_kernel_demo_seconds_remaining`,
  `dsp_kernel_reset_demo`, `dsp_kernel_set_subscription_status`,
  `dsp_kernel_subscription_status`, `dsp_kernel_grace_deadline_unix`,
  `dsp_kernel_set_licensed`, `dsp_kernel_public_key`). `conjure_dsp.h`
  regenerates via cbindgen.

Swift — deleted files:
- `ConjureDSPExtension/Model/SubscriptionManager.swift`
- `ConjureDSPExtension/Model/SubscriptionAPI.swift`
- `ConjureDSPExtension/Model/BetaMode.swift`
- `ConjureDSPExtension/UI/SubscriptionSettingsView.swift`
- `ConjureDSP/Model/PaddleCheckoutManager.swift`

Swift — edited call sites:
- `ConjureDSPExtensionAudioUnit.swift`: removed the license wrapper methods.
- `AudioUnitViewController.swift`: removed `SubscriptionManager` creation +
  kernel-closure wiring. (The separate `BuildID`-label read stays.)
- `ConjureDSPExtensionMainView.swift`: removed the demo-expired overlay + the
  `subscriptionManager` property.
- `PresetToolbar.swift`: removed DEMO/BETA badges, the export license lock, the
  License settings tab, and the `openLicenseSettings` notification.
- `ExportPopover.swift`: removed the `isLicensed` parameter + warning + guard.
- `Analytics.swift`: `BuildMode` collapsed to `debug`/`release`; removed
  `updateMode`, the `subscriptionActivate` event, and `identify(licenseHash:)`.
- `SentryHelper.swift`: removed `configureUser(subscriptionStatus:email:)`.
- `ConjureDSPApp.swift`: removed the `conjuredsp://subscribe` deep-link handler.
- Export template: removed the `dsp_kernel_set_licensed(kernel, true)` call.

Build config / tooling:
- `project.pbxproj`: dropped `BETA_BUILD` from all `SWIFT_ACTIVE_COMPILATION_CONDITIONS`.
- `scripts/build.sh`: removed the `--beta` flag.
- Skills `build-run`, `build-release`, `try-it`: removed the beta build option.
- `BuildID` stamping is intentionally KEPT (it feeds the visible build-ID label).

Tests: deleted the beta/subscription test files and pruned the now-defunct
`dsp_kernel_set_licensed(kernel, true)` calls and demo/subscription UI assertions.

Server (`server/`): the whole directory was deleted from the repo (Cloudflare
Worker: `/activate`, `/verify`, `/webhooks/paddle`, `/health`, D1 `schema.sql`,
`wrangler.toml`). Recover with `git show 0cb82d7:server/...` if needed.

## External infrastructure (NOT code — separate ops teardown)

These live outside the repo and only supported the subscription. They are being
decommissioned via Asana tasks. To restore the paywall you would re-provision:

- Cloudflare Worker at `api.conjuredsp.com` (+ its DNS/route) — `wrangler deploy`.
- Cloudflare D1 database `conjuredsp-db`.
- Worker secrets: `PADDLE_API_KEY`, `PADDLE_WEBHOOK_SECRET`, `ED25519_PRIVATE_KEY`.
- Paddle Billing product/plan + webhook destination.
- The Ed25519 license-signing keypair (dev-machine Keychain). **Keep this if you
  might restore** — losing it means every previously issued token is
  unverifiable. It is distinct from the Sparkle EdDSA update key
  (`https://sparkle-project.org` Keychain item) — do not confuse or delete that.

Note: `plans/activation-tracking-soft-limit.md` is a now-obsolete plan against
the removed server; kept only as historical context.

## Re-enable checklist (future you)

1. `git revert <removal-sha>` (or cherry-pick the pre-removal files from `0cb82d7`).
2. Redeploy the Worker + recreate D1 + re-add secrets; re-point Paddle's webhook.
3. Restore the Ed25519 keypair to the dev Keychain (see `scripts/restore-keypair.sh`).
4. Rebuild; verify demo silencing, export gating, and token verification.
