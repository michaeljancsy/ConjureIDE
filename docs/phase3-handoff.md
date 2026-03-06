# Phase 3: Export UI — Handoff Document

## Current State

**Branch:** `export-phase3-ui` (committed as `55f5a2d`)
**Status:** Feature is functional with one remaining bug to fix.

The export flow works end-to-end: user clicks Export in toolbar, enters a name, the preset gets packaged into a standalone AUv3 `.app` bundle, installed to `~/Library/Application Support/BearBone/Exports/`, code signed, and registered with LaunchServices. The exported AU should then appear in DAWs.

## What Works

1. **Export button** in toolbar with popover (editable effect name, language display, Export/Cancel)
2. **Export pipeline**: unzips template → injects preset (Python .py or Rust .wasm) → patches plists (bundle ID, AU subtype, display name) → code signs → registers in export registry
3. **Template embedding**: Pre-built template stored as `ExportTemplate.zip` in extension Resources (must be zipped — raw `.app` causes PluginKit to discover the template's embedded `.appex` and register it, which blocks the main BearBone extension from registering)
4. **App Group staging** for DAW context: extension writes unsigned bundle to `group.com.MichaelJancsy.BearBone` App Group container
5. **PendingExportHandler** in host app: on launch, checks App Group's `PendingExports/`, moves to Exports dir, code signs individual items in Frameworks (not the directory itself), registers with `lsregister`
6. **Direct export** path (host app context): exports directly to final location with signing + LaunchServices registration, no restart needed

## The Bug: Host App Detection Not Working

### Problem
When running in the BearBone host app, exports still go through the DAW path (App Group staging) and show "Open BearBone to install" instead of doing a direct install. The `isInHostApp` detection in `AudioUnitViewController.swift:279-282` is failing.

### Current detection code (`AudioUnitViewController.swift:279-282`)
```swift
let mainBundleId = Bundle.main.bundleIdentifier ?? ""
let isInHostApp = mainBundleId == "com.MichaelJancsy.BearBone"
    || mainBundleId.hasPrefix("com.MichaelJancsy.BearBone.BearBoneExtension")
    || ProcessInfo.processInfo.processName == "BearBone"
```

### What was tried
1. `ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil` — always true because the extension itself has sandbox entitlements
2. `Bundle.main.bundleIdentifier == "com.MichaelJancsy.BearBone"` — doesn't match (AU extensions may return their own bundle as main)
3. Added `processName == "BearBone"` fallback — still not matching

### Debugging approach needed
Add a `log.info()` that prints `Bundle.main.bundleIdentifier`, `ProcessInfo.processInfo.processName`, and `Bundle.main.bundlePath` to understand what values are actually available at runtime. Then use the correct value for detection.

### Alternative approach
Instead of trying to detect the host, try to spawn `codesign` and see if it succeeds. If the sandbox blocks it, fall back to App Group staging. This would be a reliable runtime check regardless of host identity.

## Key Architecture Decisions

### Why zip the template?
PluginKit recursively scans `.app` bundles and registers any `.appex` it finds. When the template was embedded as a raw `.app` in the extension's Resources, PluginKit would register the template's `.appex` and somehow prevent the main BearBone extension from registering. Renaming `.appex` to `.appex-template` didn't help — PluginKit still found it. Zipping the template completely hides it from PluginKit.

### Why App Group for DAW exports?
AU extensions running in DAWs are sandboxed and cannot:
- Spawn processes (no `codesign`, no `lsregister`)
- Show `NSSavePanel`
- Write outside the sandbox

The App Group container (`group.com.MichaelJancsy.BearBone`) is accessible from both the sandboxed extension and the unsandboxed host app. The extension stages unsigned bundles there, and the host app finalizes them.

### Why doesn't the host app need the App Group entitlement?
The BearBone host app is **not sandboxed** (`com.apple.security.app-sandbox` is not in its entitlements). Unsandboxed apps can access `~/Library/Group Containers/group.com.MichaelJancsy.BearBone/` directly without needing the App Group entitlement in their provisioning profile. Adding the entitlement to the host app caused a provisioning profile error, so it was removed. `PendingExportHandler` uses the direct filesystem path instead of `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`.

### Why `lsregister` instead of `NSWorkspace.shared.open()`?
The exported `.app` is not a real launchable application — it's just a container for the AU extension. `NSWorkspace.shared.open()` tries to launch it and shows "can't be opened" errors. `lsregister -f -R -trusted` registers the `.app` with LaunchServices, which makes PluginKit discover the embedded `.appex` and register it as an AU — without trying to launch anything.

### Code signing individual Frameworks items
The `PendingExportHandler` must sign each item inside `Contents/Frameworks/` individually (e.g., `libpython3.14t.dylib`), not the Frameworks directory itself. Signing the directory fails with "bundle format unrecognized."

## Files Changed (Phase 3)

### New files
- `BearBoneExtension/UI/ExportPopover.swift` — SwiftUI popover for export config (name field, language label, Export/Cancel buttons, `ExportResult` enum)
- `BearBone/Model/PendingExportHandler.swift` — Host app handler that finalizes staged exports

### Modified files
- `BearBoneExtension/BearBoneExtension.entitlements` — Added `com.apple.security.application-groups` with `group.com.MichaelJancsy.BearBone`
- `BearBoneExtension/Export/ExportManager.swift` — Added `skipSigning` parameter, `appGroupContainerURL()`, `appGroupIdentifier`, changed `copyTemplate` to `unzipTemplate` (uses `ditto -xk`)
- `BearBoneExtension/Common/Audio Unit/BearBoneExtensionAudioUnit.swift` — Added `public var wasmBytes: Data?` accessor
- `BearBoneExtension/UI/PresetToolbar.swift` — Added Export button with popover, `onExport` closure, `isExporting`/`showingExport`/`exportName` state
- `BearBoneExtension/UI/BearBoneExtensionMainView.swift` — Added `onExport` closure parameter, export state management, alert for export result
- `BearBoneExtension/Common/UI/AudioUnitViewController.swift` — Export closure implementation with host app vs DAW detection, direct export path with code signing + lsregister
- `BearBone/BearBoneApp.swift` — Added `PendingExportHandler` instance, calls `checkForPendingExports()` on launch
- `BearBone/ContentView.swift` — Added export handler alerts (installed + error)
- `BearBone.xcodeproj/project.pbxproj` — Added "Copy Export Template" build phase (zips template into Resources)
- `BearBoneTests/ExportManager.swift` — Synced copy of extension's ExportManager
- `BearBoneTests/ExportTests.swift` — Added 3 new tests (skipSigning, sanitize, App Group URL)
- `backlog.md` — Updated Phase 3 status
- `docs/export-au-plan.md` — Updated Phase 3 section

## Build Prerequisites

### Export template must be pre-built
```bash
cd BearBoneExportAUTemplate
xcodebuild -scheme BearBoneExportAUTemplate -configuration Release -arch arm64 build
```
The built `.app` goes to DerivedData. It must then be copied to where the build phase expects it:
```bash
mkdir -p BearBoneExportAUTemplate/build/Build/Products/Release
rsync -a ~/Library/Developer/Xcode/DerivedData/BearBoneExportAUTemplate-*/Build/Products/Release/BearBoneExportAUTemplate.app/ BearBoneExportAUTemplate/build/Build/Products/Release/BearBoneExportAUTemplate.app/
```
The "Copy Export Template" build phase zips this into the extension's Resources as `ExportTemplate.zip`.

### App Groups capability
The **BearBoneExtension** target must have the App Groups capability enabled in Xcode Signing & Capabilities with `group.com.MichaelJancsy.BearBone`. This has been done in the current dev environment.

## Test Status

- Existing tests all pass
- 3 new tests added (`exportWithSkipSigning`, `sanitizeSpecialCharacters`, `appGroupContainerURL`) but could not be verified due to a pre-existing CodeSign issue in the test target (XCUIAutomation.framework signing failure)
- End-to-end manual test: export from host app works, `.app` appears in Exports dir, code signing succeeds, `lsregister` runs

## What's Left for Phase 3

1. **Fix host app detection** (the main bug described above)
2. **Verify exported AU appears in DAW** (after lsregister, check `pluginkit -mv -p com.apple.AudioUnit-UI` and test in Logic/Ableton)
3. **Test DAW export path** (load BearBone in a DAW, export, then open BearBone host app to finalize)

## What's Next (Phase 4+)

Per `backlog.md`:
- **Phase 4: Python export support** — Shared Python runtime at `~/Library/Application Support/BearBone/PythonRuntime-3.14/`, error UI with auto-download if runtime missing
- **Phase 5: Polish & validation** — Integration tests, edge cases, documentation
