# Release Pipeline

Run `scripts/release.sh` to build, sign, notarize, and package a distributable DMG. The script orchestrates: `xcodebuild archive` → `xcodebuild -exportArchive` with Developer ID signing → notarize app → create DMG → notarize DMG → staple.

## Provisioning profiles

Developer ID provisioning profiles must be created on the Apple Developer portal for both bundle IDs (`com.MichaelJancsy.ConjureDSP` and `com.MichaelJancsy.ConjureDSP.ConjureDSPExtension`). After downloading, copy them with UUID-based filenames to `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`:

```bash
# Extract UUID and install properly
UUID=$(security cms -D -i <profile>.provisionprofile | grep -A1 UUID | tail -1 | sed 's/.*<string>//' | sed 's/<\/string>//')
cp <profile>.provisionprofile ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/${UUID}.provisionprofile
```

`ExportOptions.plist` uses `signingStyle: manual` with explicit profile name mappings, since automatic signing doesn't reliably find Developer ID profiles from CLI builds.

## Re-signing after export

`build-release.sh` modifies the exported app bundle (re-signs rustc-dist, export template) then re-signs the extension and host app. **Critical**: the re-sign must use `--preserve-metadata=entitlements`, NOT `--entitlements <file>`. The entitlements file only contains a subset; `xcodebuild -exportArchive` injects additional entitlements (`com.apple.application-identifier`, `com.apple.developer.team-identifier`, `com.apple.security.app-sandbox`, etc.) that pkd requires to discover the AU extension. If these are stripped, the extension silently fails to register — no errors in logs, just absent from `pluginkit -mv`.

## Entitlement pitfalls

- **Never add `inter-app-audio`** — it's deprecated and not covered by Developer ID provisioning profiles. macOS will SIGKILL the app on launch with `zsh: killed` (no useful error message).
- Hardened runtime exceptions (`allow-jit`, `allow-unsigned-executable-memory`) and sandbox entitlements (`network.client`, `files.user-selected.read-only`) are unrestricted for Developer ID and don't need profile coverage.

## Verifying a release build

After building, verify locally before distributing:

```bash
# Check extension registers with pluginkit
open build/release/ConjureDSP.app
sleep 5
pluginkit -mv -p com.apple.AudioUnit-UI | grep ConjureDSP

# Verify signing
codesign -v --deep --strict build/release/ConjureDSP.app
spctl --assess --type execute -v build/release/ConjureDSP.app
```

If the extension doesn't register, check for stale LaunchServices entries (see `au-registration-troubleshooting.md`). On a test machine, if the app was opened from the DMG volume before copying to `/Applications/`, unregister the stale `/Volumes/` path first:

```bash
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister
$LSREGISTER -u /Volumes/ConjureDSP/ConjureDSP.app 2>/dev/null
$LSREGISTER -f -R -trusted /Applications/ConjureDSP.app
killall -9 pkd AudioComponentRegistrar 2>/dev/null
```
