# Sparkle Integration Plan

## Policy

- **Notify-only.** Updates are never installed without explicit user approval. DAW sessions are too fragile for silent plugin updates. Sparkle checks in the background once per day and surfaces a dialog when a new version exists; nothing is installed until the user clicks through.
  - `SUAutomaticallyUpdate = NO` disables silent installs.
  - `SUAllowsAutomaticUpdates = NO` hides the "Automatically install updates" checkbox in Sparkle's UI so the policy cannot be flipped at runtime.
  - `SUEnableAutomaticChecks = YES` with `SUScheduledCheckInterval = 86400` handles background checks.
- **Rollback is supported.** Every released DMG is retained in Cloudflare R2 forever. The app's "Previous Versions…" menu item opens a web page listing all historic versions, each downloadable directly. Drag-to-Applications replaces the current app; presets, license, and other data live in the App Group container and are preserved across version changes.

## Hosting

Cloudflare R2 bucket `conjuredsp-updates`, served publicly via custom domain `updates.conjuredsp.com`. Same Cloudflare account as the subscriptions Worker (`server/wrangler.toml` → `api.conjuredsp.com`), so wrangler auth is shared. R2 free tier (10GB storage, 10M reads/mo) comfortably covers the expected release cadence and 100MB–2GB DMG size.

Files served at the root of the bucket:
- `appcast.xml` — Sparkle feed, rolling (overwritten each release). Contains an `<item>` per historic version with EdDSA signatures.
- `ConjureDSP-<version>.dmg` — notarized installer per version. Never overwritten or deleted.
- `versions.html` — static page listing every version from `appcast.xml`, linked from the app's "Previous Versions…" menu item.

## What's done

- Sparkle 2.x added as SPM dependency (host app only).
- `SPUStandardUpdaterController` initialized at app launch.
- "Check for Updates…" menu item under the app menu.
- "Previous Versions…" menu item opens `https://updates.conjuredsp.com/versions.html`.
- Notify-only policy wired into Release build settings (`INFOPLIST_KEY_SU*`).
- `INFOPLIST_KEY_SUFeedURL` set to `https://updates.conjuredsp.com/appcast.xml`.
- `release.sh` preserves `APPCAST_DIR` across runs, syncs historic DMGs from R2, regenerates `appcast.xml` + `versions.html`, and uploads DMG + `appcast.xml` + `versions.html` to R2.
- Unit tests for the updater view model.

## What's left (manual, one-time)

### 1. EdDSA keypair — done on the main dev machine

The signing keypair has been generated via Sparkle's `generate_keys` tool and the public key is wired into `INFOPLIST_KEY_SUPublicEDKey` in the Release build settings. The private key lives in the login Keychain of the dev machine (item: `https://sparkle-project.org`, account: `ed25519`) and `generate_appcast` picks it up automatically during `release.sh`.

If you ever need to regenerate or set this up on a new signing machine:

```bash
# generate_keys is bundled with Sparkle's SPM artifacts, not on PATH
xcodebuild -project ConjureDSP.xcodeproj -scheme ConjureDSP build
find ~/Library/Developer/Xcode/DerivedData -name generate_keys -type f | head -1 | xargs -I {} {}
```

It prints a `<string>...</string>` block containing the public key. Paste the base64 value into `INFOPLIST_KEY_SUPublicEDKey` in `project.pbxproj` (Release config of the host app target). **Back up the private key** — losing it means existing installs can never receive updates signed with a new key without first shipping an app update that embeds the new public key, which is a painful migration.

### 2. Provision the R2 bucket

```bash
wrangler r2 bucket create conjuredsp-updates
```

Then in the Cloudflare dashboard: **R2 → conjuredsp-updates → Settings → Public access → Connect Domain**, attach `updates.conjuredsp.com`. DNS for `conjuredsp.com` is already managed by Cloudflare (same zone as `api.conjuredsp.com`), so this just requires one click + CNAME approval.

### 3. Per-release release notes (optional)

Sparkle displays release notes in the update dialog. Drop a `<version>.html` file into `build/release/appcast/` before running `release.sh` and `generate_appcast` will pick it up and reference it from the feed. Skip until the first real release.

### 4. End-to-end test

See the Verification section of `plans/humming-marinating-torvalds.md` (plan file) for the full smoke-test script: build v1.0, bump to v1.0.1, re-run release, confirm Check for Updates offers the update without installing, click Install, confirm it applies, then roll back via the Previous Versions… page.
