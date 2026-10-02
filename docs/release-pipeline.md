# Release Pipeline

Run `scripts/build-and-release.sh` (or the `build-release` skill) to build, sign, notarize, package, and publish. `scripts/build.sh` does `xcodebuild archive` → upload and verify dSYMs on Sentry → copy the app out of the archive, strip, re-sign → notarize app → create DMG → notarize DMG. `scripts/release.sh` then generates the Sparkle appcast and uploads the DMG to R2.

## Provisioning profiles

Developer ID provisioning profiles must be created on the Apple Developer portal for both bundle IDs (`com.MichaelJancsy.ConjureDSP` and `com.MichaelJancsy.ConjureDSP.ConjureDSPExtension`). After downloading, copy them with UUID-based filenames to `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`:

```bash
# Extract UUID and install properly
UUID=$(security cms -D -i <profile>.provisionprofile | grep -A1 UUID | tail -1 | sed 's/.*<string>//' | sed 's/<\/string>//')
cp <profile>.provisionprofile ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/${UUID}.provisionprofile
```

`ExportOptions.plist` uses `signingStyle: manual` with explicit profile name mappings, since automatic signing doesn't reliably find Developer ID profiles from CLI builds.

## Re-signing after export

`build.sh` modifies the exported app bundle (re-signs rustc-dist, export template) then re-signs the extension and host app. **Critical**: the re-sign must use `--preserve-metadata=entitlements`, NOT `--entitlements <file>`. The entitlements file only contains a subset; `xcodebuild -exportArchive` injects additional entitlements (`com.apple.application-identifier`, `com.apple.developer.team-identifier`, `com.apple.security.app-sandbox`, etc.) that pkd requires to discover the AU extension. If these are stripped, the extension silently fails to register — no errors in logs, just absent from `pluginkit -mv`.

## Debug symbols (Sentry)

`build.sh` runs `scripts/upload-dsyms.sh` right after `xcodebuild archive`. It uploads the archive's `dSYMs/` folder plus the extension's `libpython3.14t.dylib` (python-build-standalone ships no dSYM for it), then asks the Sentry API for every Mach-O UUID and fails the build if any is missing. A credentials check runs before the archive starts, so a missing or invalid token fails in seconds rather than after the archive.

- The destination is hard-coded: org `michael-jancsy`, project `conjuredsp`. `~/.sentryclirc`'s default project is conjurealign, so never run a bare `sentry-cli debug-files upload`.
- Token: `SENTRY_AUTH_TOKEN`, else `token=` under `[auth]` in `~/.sentryclirc`. An org auth token with `org:ci` scope covers both the upload and the verification query.
- `build/ConjureDSP.xcarchive` is overwritten by the next build, so right after archiving `build.sh` also keeps a slim copy (~75 MB of the ~2.7 GB archive: `dSYMs/`, `Info.plist`, and libpython) at `~/Library/Developer/ConjureDSP/ReleaseSymbols/ConjureDSP-<version>-b<build>-<timestamp>.xcarchive`. It lives outside the checkout so worktree builds keep theirs too.
- To upload or re-check any archive, full or kept: `scripts/upload-dsyms.sh <path>.xcarchive`. Re-running is safe; Sentry skips files it already has.
- Releases before 3.1.0 have no surviving dSYMs. Their shipped (stripped) executables were uploaded from the R2 DMGs on 2026-10-02. That gives Sentry stack unwinding plus the function names the release build kept (~32k symbols in the 3.0.2 extension), but not file/line info.

There is deliberately no Xcode build phase for this. The previous one sat on the host-app target and read a gitignored `${SRCROOT}/.sentryclirc`; no checkout had that file, so the phase printed a warning (hidden by `build.sh`'s `| tail -1`) and exited 0. That is how 3.1.0 (build 25) shipped with no symbols on Sentry. The phase also ran under Xcode's user-script sandbox with only the script and `.sentryclirc` declared as inputs, which blocks reading the dSYMs it was meant to upload.

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
