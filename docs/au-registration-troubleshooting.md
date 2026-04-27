# AU Registration Troubleshooting

## Dangerous commands — NEVER use

- **`pluginkit -r`** — Permanently removes an extension from PluginKit's registry. Despite Apple's documentation claiming this "cannot make permanent alterations," the removal persists across reboots, DerivedData deletion, AU cache clearing, app relaunches, and even `pluginkit -e default`. Recovery requires purging stale LaunchServices entries (see below). **There is no safe use case for `pluginkit -r` during development.**
- **`pluginkit -e ignore`** — Suppresses an extension's registration. If the build fails before a corresponding `pluginkit -e default` runs, the extension stays suppressed indefinitely. Avoid in build scripts.

## How AU extension registration works

1. **LaunchServices** tracks which apps exist and where they live on disk
2. **PluginKit (pkd)** discovers extensions embedded in LaunchServices-registered apps
3. **AudioComponentRegistrar** reads PluginKit's registry to make AUs available to hosts

Registration breaks when any layer has stale or corrupted state.

## Common failure: stale LaunchServices entries

Over time, LaunchServices accumulates entries from old DerivedData directories that no longer exist. If multiple stale entries claim the same bundle ID, PluginKit may fail to discover the extension even from a valid, freshly-built app. This is the most common cause of "AU component not found" errors, especially for the Release bundle ID (which was shared across Debug/Release builds before the bundle ID separation was added).

**Diagnosis:** Check if LaunchServices has stale entries:
```bash
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister
$LSREGISTER -dump | grep -B20 "identifier:.*com\.MichaelJancsy\.ConjureDSP$" | grep "path:"
```
If this shows paths to DerivedData directories that no longer exist, that's the problem.

## Recovery procedure

If an AU disappears from hosts (`Failed to find Audio Unit component`):

**Step 1: Basic recovery**
```bash
killall -9 AudioComponentRegistrar
rm -f ~/Library/Caches/AudioUnitCache/com.apple.audiounits.cache
```
Rebuild and relaunch from Xcode. This fixes most transient issues.

**Step 2: If Step 1 fails — purge stale LaunchServices entries**

This is the fix for `pluginkit -r` damage and stale registration conflicts:
```bash
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister

# Unregister ALL stale ConjureDSP entries from LaunchServices
$LSREGISTER -dump | grep -B20 "identifier:.*com\.MichaelJancsy\.ConjureDSP" | grep "path:" | sed 's/.*path:[[:space:]]*//' | sed 's/ (0x.*//' | while read -r path; do
    echo "Unregistering: $path"
    $LSREGISTER -u "$path" 2>/dev/null
done

# Re-register ONLY the current build
$LSREGISTER -f -R -trusted ~/Library/Developer/Xcode/DerivedData/ConjureDSP-*/Build/Products/Release/ConjureDSP.app
$LSREGISTER -f -R -trusted ~/Library/Developer/Xcode/DerivedData/ConjureDSP-*/Build/Products/Debug/ConjureDSP.app

# Restart PluginKit and AudioComponentRegistrar
killall -9 pkd AudioComponentRegistrar
```
Wait a few seconds, then rebuild and launch from Xcode.

**Step 3: If Step 2 fails — reset PluginKit election state**

PluginKit stores election preferences (enabled/disabled) in an Annotations plist:
```bash
# Find it (path varies by machine):
find /private/var/folders -name "Annotations" -path "*/com.apple.pluginkit/*" 2>/dev/null

# Inspect it:
cat /private/var/folders/<your-path>/0/com.apple.pluginkit/Annotations
# Look for your bundle ID with election = 0 (disabled)

# Fix it:
/usr/libexec/PlistBuddy -c "Set :data:com.MichaelJancsy.ConjureDSP.ConjureDSPExtension:election 1" <path-to-Annotations>
killall -9 pkd AudioComponentRegistrar
```

**Step 4: Nuclear option — full LaunchServices database reset**
```bash
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister
$LSREGISTER -kill -r -domain local -domain system -domain user
```
This resets ALL LaunchServices registrations system-wide. Apps will re-register as they're launched. Use only as a last resort.

## Prevention

- **Never use `pluginkit -r` or `pluginkit -e ignore` in build scripts.** The post-build `bust-au-cache.sh` uses only `killall AudioComponentRegistrar` + `lsregister`, which are safe.
- **Move `/Applications/ConjureDSP.app` during development** if a production install exists — it shadows DerivedData builds via PluginKit. The pre-build script handles this automatically.
- **Periodically clean old DerivedData** — stale entries accumulate in LaunchServices and can cause registration conflicts: `ls ~/Library/Developer/Xcode/DerivedData/ConjureDSP-*`

## Useful diagnostic commands

- `pluginkit -mv -p com.apple.AudioUnit-UI` — list registered AU extensions with paths (look for `+` prefix = elected)
- `pluginkit -m | grep ConjureDSP` — search all protocols (not just AU)
- `auval -v aufx 0001 CONJ` — validate the Release AU component
- `auval -v aufx DBG1 CONJ` — validate the Debug AU component
- `codesign -v -vvv <path-to-app>` — verify code signing is valid
- `codesign -d --entitlements - <path-to-appex>` — inspect extension entitlements
