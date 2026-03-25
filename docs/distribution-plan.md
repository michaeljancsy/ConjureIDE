# ConjureDSP Distribution Plan

Distribution via Paddle (payments + license delivery) and GitHub (DMG hosting + release management).

## Overview

```
User visits website → clicks Buy → Paddle checkout → license key emailed
                    → clicks Download → GitHub Releases → DMG
User installs app → enters license key → Ed25519 verification → unlocked
```

## Phase 1: Pre-Launch Setup

### 1A. Paddle Account

1. Sign up at paddle.com (Paddle Billing)
2. Complete seller verification (business details, tax info — takes 2-5 business days)
3. Create a one-time product for ConjureDSP
   - Set price, description, icon
   - Paddle handles global tax/VAT as merchant of record

### 1B. License Key Delivery

**Start simple: pre-generated batch**

1. Generate a batch of license keys:
   ```bash
   cd tools/generate-license
   for i in $(seq 1 100); do
     cargo run -- generate >> keys.txt
   done
   ```
2. In Paddle, set up fulfillment to deliver a unique key from the batch on purchase
3. Customize the purchase confirmation email template to include:
   - The license key
   - Installation instructions
   - Link to download from GitHub Releases

**Later: automated webhook**

When batch management gets tedious, deploy a serverless function:
- Paddle sends webhook on `transaction.completed`
- Function calls `generate-license` and emails the key
- Cloudflare Worker or AWS Lambda — minimal, stateless
- Store issued keys in a simple database for support lookups

### 1C. GitHub Releases

1. Create releases on the existing repo (or a dedicated public `conjuredsp/releases` repo if the main repo is private)
2. Each release:
   - Tag: `v1.0.0`
   - Title: `ConjureDSP v1.0.0`
   - Release notes (changelog)
   - Attach the notarized DMG as a release asset
3. Direct download URL: `https://github.com/<org>/<repo>/releases/latest/download/ConjureDSP.dmg`

### 1D. Release Workflow

Extend the existing `scripts/release.sh` to automate the full flow:

```bash
# Existing steps (already implemented):
# 1. Archive Release build with Developer ID signing
# 2. Notarize with Apple
# 3. Create DMG

# New steps to add:
# 4. Create GitHub Release + upload DMG
VERSION=$(defaults read "$(pwd)/ConjureDSP/Info.plist" CFBundleShortVersionString)
gh release create "v${VERSION}" \
  --title "ConjureDSP v${VERSION}" \
  --notes-file CHANGELOG.md \
  "build/ConjureDSP-${VERSION}.dmg"
```

## Phase 2: Website

A single-page static site. GitHub Pages or Netlify (free).

### Required sections:
- **Hero**: product name, one-line pitch, screenshot/video
- **Features**: key capabilities (Python/Rust scripting, AI assistant, spectrogram, etc.)
- **Audio demos**: embedded audio players showing before/after
- **Download**: link to GitHub Releases latest DMG
- **Buy**: Paddle checkout button (Paddle.js overlay — user never leaves your site)
- **License activation**: instructions for entering key in-app
- **Support**: email or link to GitHub Issues

### Paddle.js integration

```html
<script src="https://cdn.paddle.com/paddle/v2/paddle.js"></script>
<script>
  Paddle.Initialize({ token: 'your_client_token' });
</script>
<button onclick="Paddle.Checkout.open({ items: [{ priceId: 'pri_xxx', quantity: 1 }] })">
  Buy ConjureDSP — $XX
</button>
```

Checkout opens as an overlay. No redirect. User pays, gets email with license key.

## Phase 3: Auto-Updates (Sparkle)

Add after initial launch when there's something to update to.

### Integration steps:

1. Add Sparkle via Swift Package Manager:
   ```
   https://github.com/sparkle-project/Sparkle
   ```
   Add to the **host app** target (not the extension).

2. Configure `Info.plist`:
   ```xml
   <key>SUFeedURL</key>
   <string>https://<your-domain>/appcast.xml</string>
   <key>SUPublicEDKey</key>
   <string>your-ed25519-public-key</string>
   ```

3. Add update check in host app launch:
   ```swift
   import Sparkle
   let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
   ```

4. Generate `appcast.xml` when releasing:
   ```bash
   # Sparkle's generate_appcast tool
   ./bin/generate_appcast /path/to/dmg/directory
   ```

5. Host `appcast.xml` on your website (or GitHub Pages). It's a simple XML feed:
   ```xml
   <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
     <channel>
       <item>
         <title>v1.1.0</title>
         <sparkle:version>42</sparkle:version>
         <sparkle:shortVersionString>1.1.0</sparkle:shortVersionString>
         <enclosure url="https://github.com/.../ConjureDSP-1.1.0.dmg"
                    sparkle:edSignature="..." length="12345678" type="application/octet-stream"/>
       </item>
     </channel>
   </rss>
   ```

### How updates work with AUv3:
- Sparkle updates the host app (ConjureDSP.app)
- The AUv3 extension is embedded inside the app bundle
- Updating the app automatically updates the plugin for all DAWs
- DAWs pick up the new extension version on next launch (or next AU scan)

## Phase 4: In-App License Flow Polish

The Ed25519 license system already works. Polish the user-facing flow:

1. **First launch**: show a welcome screen with fields for license key entry and a "Buy" link (opens website)
2. **Invalid key**: clear error message, link to support
3. **Demo mode**: current 60-second demo is good. Add a persistent "Buy" button in the UI that opens the Paddle checkout URL
4. **License recovery**: add a "Lost your key?" link pointing to Paddle's customer portal (Paddle provides this)

## Implementation Order

| Step | What | Effort | Dependency |
|------|------|--------|------------|
| 1 | Paddle account + product setup | 1-2 hours + wait for approval | None |
| 2 | Pre-generate license key batch | 30 min | Paddle approved |
| 3 | Set up GitHub Releases in release.sh | 1-2 hours | None |
| 4 | Landing page (static site) | 1-2 days | Paddle client token |
| 5 | First release: run release.sh, upload DMG | 1 hour | Steps 1-4 |
| 6 | In-app "Buy" link + license entry polish | Half day | Paddle checkout URL |
| 7 | Sparkle auto-updates | Half day | After first update needed |
| 8 | Automated license webhook | Half day | When batch runs low |

## Checklist Before First Release

- [ ] Paddle account approved and product created
- [ ] License keys pre-generated and uploaded to Paddle fulfillment
- [ ] `release.sh` tested end-to-end (archive → notarize → DMG → GitHub Release)
- [ ] DMG verified on a clean Mac (no dev tools installed)
- [ ] Landing page live with Buy button + Download link
- [ ] In-app license entry tested with a real key
- [ ] Demo mode tested (60-second timer, then silence)
- [ ] Support email set up
