# Phase 3 Export: Bug Fixes & Integration Test — Handoff

## What Was Done

Three bugs were found and fixed in the Phase 3 export pipeline, and an end-to-end integration test was added that verifies exported AUs are discoverable by DAWs.

### Bug 1: Host App Detection Failing

**Root cause:** AUv3 view controllers run in a ViewBridge XPC process, even when the audio unit itself is loaded in-process via `.loadInProcess`. In this XPC process, `Bundle.main` is the ViewBridge service bundle — NOT the host app's bundle. So all identity-based checks (`Bundle.main.bundleIdentifier`, `ProcessInfo.processName`) fail.

**Fix:** Replaced identity-based `isInHostApp` detection with capability-based try/fallback in `AudioUnitViewController.swift`:
1. Try direct export (with signing + lsregister) first
2. If it fails (sandbox blocks `Process()`), clean up partial export and fall back to App Group staging

This eliminates host detection entirely — the code just tries the direct path and degrades gracefully.

### Bug 2: Code Signing Strips Sandbox Entitlements

**Root cause:** `codesign -s - --force --deep` strips the `com.apple.security.app-sandbox` entitlement that was embedded by Xcode when the template was originally built. Without this entitlement, PluginKit refuses to register the extension — it silently ignores it.

**Fix:** Changed `codeSign()` in both `ExportManager.swift` and `PendingExportHandler.swift`:
- Removed `--deep` (we already sign in correct order: frameworks → appex → app)
- Added `--preserve-metadata=entitlements` to keep the original sandbox entitlements

### Bug 3: Frameworks Directory Signing Fails

**Root cause:** `ExportManager` called `codeSign()` on the `Contents/Frameworks/` directory itself. `codesign` rejects directories with "bundle format unrecognized." `PendingExportHandler` already did it correctly (enumerating items inside).

**Fix:** `ExportManager` now enumerates items inside `Contents/Frameworks/` and signs each individually (dylibs, .so files), matching `PendingExportHandler`.

### Test Fixes

**Existing export tests were broken:** `createMockTemplate()` created a raw `.app` directory, but `ExportManager.exportPreset()` calls `unzipTemplate()` which expects a `.zip` file. Fixed by zipping the mock template with `ditto -ck`.

This fixed 3 previously-failing tests: `exportRustPreset`, `exportPythonPreset`, `exportWithSkipSigning`.

### New End-to-End Integration Test

`ExportIntegrationTests/exportAndRegisterRustPreset()` does a full round-trip with the real template:
1. Exports a Rust preset with signing via `ExportManager`
2. Verifies `.app` bundle structure (`.appex` inside)
3. Verifies code signature (`codesign --verify --deep --strict`)
4. Registers with LaunchServices (`lsregister -f -R -trusted`)
5. Verifies AU appears in `pluginkit -mv -p com.apple.AudioUnit-UI` (with retry)
6. Verifies plist metadata (AudioComponents name, type, manufacturer)
7. Verifies export registry updated
8. Cleans up exported `.app` on exit

**Prerequisite:** The test requires `ExportTemplate.zip` in the built extension bundle. It searches DerivedData as a fallback and skips gracefully if not found.

## Files Changed

- `BearBoneExtension/Common/UI/AudioUnitViewController.swift` — Replaced identity-based host detection with try-direct/fallback-to-staging
- `BearBoneExtension/Export/ExportManager.swift` — Fixed Frameworks signing (enumerate items), fixed codesign (preserve entitlements, no --deep)
- `BearBone/Model/PendingExportHandler.swift` — Fixed codesign (preserve entitlements, no --deep)
- `BearBoneTests/ExportManager.swift` — Synced copy of ExportManager
- `BearBoneTests/ExportTests.swift` — Fixed mock template (zip it), added integration test

## Test Results

- **119 tests pass** (3 previously-failing export tests now pass, 1 new integration test passes)
- **32 tests fail** — all pre-existing (BearBoneTests AU failures from worktree registration, 1 sanitize test)

## What's Left for Phase 3

1. ~~Fix host app detection~~ ✅
2. ~~Verify exported AU appears in DAW~~ ✅ (automated via integration test)
3. **Test DAW export path** (export from DAW → open BearBone to finalize) — requires manual testing in Logic/Ableton. The DAW path uses `ditto` (Process) to unzip the template, which may fail if the DAW's sandbox blocks process spawning. If so, a Foundation-based unzip alternative would be needed.

## What's Next (Phase 4+)

Per `backlog.md`:
- **Phase 4: Python export support** — Shared Python runtime at `~/Library/Application Support/BearBone/PythonRuntime-3.14/`, error UI with auto-download if runtime missing
- **Phase 5: Polish & validation** — Integration tests, edge cases, documentation
