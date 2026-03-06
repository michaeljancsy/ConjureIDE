# AUv3 Preset Export — Implementation Plan

Export a BearBone preset (Python or Rust) as a standalone AUv3 plugin that the user can install and use in any DAW without BearBone running.

## Key Decisions

| Decision | Choice |
|----------|--------|
| Exportable languages | Both: Python (.py source) and Rust (.wasm binary only) |
| Template app behavior | Auto-register-and-quit (launch → macOS discovers .appex → terminate) |
| Template location | Separate Xcode project (its own app bundle) |
| Export trigger | Toolbar button in the AU extension UI |
| Sandbox strategy | App Group container for DAW-hosted extension writes |
| Code signing | Ad-hoc (`codesign -s -`) for local use |
| Build at export time | No — pre-built template, just copy + patch + sign |
| Shared Python runtime | `~/Library/Application Support/BearBone/PythonRuntime-3.14/` |
| Python runtime install | Auto-installed on first BearBone launch |
| Missing runtime UX | SwiftUI error view with download button that auto-installs |
| AU manufacturer code | `A000` (same as BearBone) |
| AU subtype | Hash of preset name → 4 chars, collision check against local registry |
| Exported AU UI | Minimal generic UI (labeled sliders). Error UI for missing Python runtime |
| Exported AU licensing | None — exports run freely. Only licensed BearBone users can export |
| Duplicate export | Overwrite previous (same AU identity) |
| Parameter system | Same 8 generic params for v1. Customization is future work |

## Architecture

### Bundle Structure (Exported AU)

```
MyEffect.app/
  Contents/
    Info.plist                    ← patched: bundle ID, app name
    MacOS/
      MyEffect                   ← auto-register-and-quit binary
    PlugIns/
      MyEffect.appex/
        Contents/
          Info.plist              ← patched: bundle ID, AU subtype, display name
          MacOS/
            MyEffect              ← AU extension binary (player)
          Frameworks/
            libpython3.14t.dylib  ← only for Python presets (~5-10MB)
          Resources/
            preset.py             ← Python preset source
            — OR —
            preset.wasm           ← compiled WASM binary
            runtime-config.json   ← metadata (language, python version, params)
```

### Shared Python Runtime

```
~/Library/Application Support/BearBone/
  PythonRuntime-3.14/
    lib/
      python3.14t/              ← stdlib + site-packages (numpy)
```

- Installed automatically on first BearBone launch
- Same content as `rust/python-dist/` minus the interpreter binary
- Each exported Python AU bundles only `libpython3.14t.dylib` (~5-10MB) in its own Frameworks/
- The heavy stdlib+numpy (~80-90MB) is shared via `PYTHONHOME` pointing to this location
- Versioned path allows future Python version upgrades without breaking existing exports

### Python Runtime Resolution (Exported AU)

The exported AU's Swift code searches for the runtime in order:

```swift
func findPythonHome() -> String? {
    // 1. Own bundle (standalone/full export)
    if let bundled = Bundle.main.path(forResource: "python-dist", ofType: nil) {
        return bundled
    }

    // 2. Shared location
    let shared = NSHomeDirectory() + "/Library/Application Support/BearBone/PythonRuntime-3.14"
    if FileManager.default.fileExists(atPath: shared) {
        return shared
    }

    // 3. Environment variable override (power users)
    if let env = ProcessInfo.processInfo.environment["BEARBONE_PYTHON_HOME"] {
        return env
    }

    return nil  // → show error UI
}
```

When runtime is not found:
- AU still loads (dylib is in its own bundle)
- Cannot execute Python → shows SwiftUI error view
- Error view has "Install Runtime" button that downloads Python runtime automatically
- Rust kernel falls back to passthrough (existing behavior)

### AU Identity

- **Type:** `aufx` (effect) — same as BearBone
- **Manufacturer:** `A000` — same as BearBone, identifies as BearBone family
- **Subtype:** 4-char code derived from hash of preset name
  - Hash preset name → take first 4 bytes → map to printable ASCII
  - Check against local export registry (`~/Library/Application Support/BearBone/export-registry.json`)
  - On collision, increment last char
  - Registry tracks: `{ name: string, subtype: string, bundleId: string, exportDate: string, language: string }`

### Sandbox Strategy (App Group)

The AU extension runs sandboxed in DAWs. It cannot write to arbitrary filesystem locations. Solution:

1. Define an **App Group** (e.g., `group.com.MichaelJancsy.BearBone`)
2. Both the host app and the AU extension join the App Group
3. At export time, the extension writes the assembled .app bundle to the App Group container
4. The extension notifies the user to "Open BearBone to complete export" or uses `NSWorkspace.shared.open()` to launch the host app
5. The host app (unsandboxed) moves the bundle from the App Group container to the user's chosen location (via `NSSavePanel`), performs final code signing, and reveals in Finder

Alternative (simpler but less polished): write directly to App Group container and tell the user to move it manually.

### Rust FFI Sharing

The exported AU player needs to call the same Rust DSP kernel FFI as BearBone. Two options:

1. **Static link** — Build a variant of `libbearbone_dsp.a` for the player target. Same Rust code, same FFI. The player target's build phase calls the same `build-rust.sh`.
2. **Shared framework** — Extract the Rust FFI into a framework used by both BearBone and the player. More complex, probably not worth it for v1.

Recommendation: Static link (option 1). The player target gets its own "Build Rust" build phase.

### Runtime Config JSON

Each exported AU includes a `runtime-config.json` in its Resources:

```json
{
  "version": 1,
  "language": "python",
  "pythonVersion": "3.14",
  "presetName": "My Cool Reverb",
  "exportDate": "2026-03-05T12:00:00Z",
  "bearBoneVersion": "1.0.0",
  "paramCount": 8
}
```

Or for Rust/WASM:

```json
{
  "version": 1,
  "language": "rust",
  "presetName": "Bitcrusher",
  "exportDate": "2026-03-05T12:00:00Z",
  "bearBoneVersion": "1.0.0",
  "paramCount": 8
}
```

The player AU reads this at init to determine which backend to use and how to configure it.

---

## Implementation Phases

### Phase 1: Template AU Player (New Xcode Target)

**Goal:** A minimal AUv3 that loads a DSP preset from its own bundle Resources and processes audio. WASM-only initially.

**Deliverables:**
- [ ] New separate Xcode project: `BearBonePlayer.xcodeproj` (its own app bundle)
  - Contains `BearBonePlayer` app target and `BearBonePlayerExtension` appex target
  - Lives in a `BearBonePlayer/` directory alongside the main `BearBone.xcodeproj`
- [ ] Player app: auto-register-and-quit (`NSApp.terminate()` after brief delay in `applicationDidFinishLaunching`)
- [ ] Player AU extension: `BearBonePlayerAudioUnit` (AUAudioUnit subclass)
  - Loads `preset.wasm` from own bundle Resources
  - Loads `runtime-config.json` for metadata
  - Same 8 generic parameters as BearBone
  - Render block calls Rust kernel with WASM backend
  - Minimal SwiftUI UI with labeled sliders for the 8 parameters
- [ ] Player extension links `libbearbone_dsp.a` (same Rust crate, own build phase)
- [ ] Player extension includes wasmtime runtime (already linked via Rust crate)
- [ ] Verify: manually copy a .wasm preset into player Resources, build, load in DAW

**Key files to create:**
- `BearBonePlayer/BearBonePlayer.xcodeproj` — separate Xcode project
- `BearBonePlayer/BearBonePlayer/` — host app directory
- `BearBonePlayer/BearBonePlayerExtension/` — AU extension directory
- `BearBonePlayer/BearBonePlayerExtension/Audio Unit/BearBonePlayerAudioUnit.swift`
- `BearBonePlayer/BearBonePlayerExtension/UI/PlayerSliderView.swift` — minimal labeled slider UI
- `BearBonePlayer/BearBonePlayerExtension/Info.plist` — AU component description

**Technical notes:**
- Separate project keeps the player cleanly decoupled from the main BearBone app
- The player AU uses the same Rust kernel (`dsp_kernel_create`, `dsp_kernel_process`, `dsp_kernel_load_wasm`) but NOT the Python-specific functions initially
- The player's Info.plist has placeholder AU identity values that get patched at export time
- The player project's "Build Rust" phase can reuse `build-rust.sh` since it produces the same static library
- The pre-built `BearBonePlayer.app` gets copied into `BearBone.app/Contents/Resources/ExportTemplate/` during the main BearBone build

### Phase 2: Export Pipeline

**Goal:** Given a preset (script source + compiled WASM if Rust), produce a working exported .app bundle.

**Deliverables:**
- [ ] `ExportManager` class (Swift) with `exportPreset(name:, source:, wasm:, language:) async throws -> URL`
- [ ] Pipeline steps:
  1. Locate pre-built template .app in BearBone's own bundle Resources
  2. Copy template to App Group container (or temp directory if running unsandboxed)
  3. Write preset file (`preset.py` or `preset.wasm`) into .appex Resources
  4. Generate `runtime-config.json` and write to .appex Resources
  5. Patch .app Info.plist: bundle ID, app name
  6. Patch .appex Info.plist: bundle ID, AU subtype, AU name
  7. If Python: copy `libpython3.14t.dylib` into .appex Frameworks
  8. Ad-hoc code sign the entire .app bundle (deepest first: frameworks → appex → app)
  9. Return URL to the signed .app
- [ ] `ExportRegistry` class: JSON file tracking exported AUs (name, subtype, bundle ID, date)
- [ ] Subtype generator: hash preset name → 4-char code, collision check
- [ ] Unit tests: plist patching, subtype generation, registry CRUD, code signing validation

**Key files to create:**
- `BearBoneExtension/Export/ExportManager.swift`
- `BearBoneExtension/Export/ExportRegistry.swift`
- `BearBoneExtension/Export/SubtypeGenerator.swift`

**Technical notes:**
- Pre-built template: The BearBonePlayer target's built product needs to be copied into BearBone's bundle during the build. Add a "Copy Player Template" build phase to the main BearBone target that copies `BearBonePlayer.app` into `BearBone.app/Contents/Resources/ExportTemplate/`
- Code signing order matters: sign frameworks first, then appex, then app. Use `codesign -s - --force --deep` or explicit per-component signing
- The template .app binary is universal (if needed) or arm64-only (matching BearBone's deployment target)
- For Rust presets, the WASM is already compiled (user clicked Run in BearBone). Just embed the cached .wasm from `WasmCache`

### Phase 3: Export UI in AU Extension

**Goal:** User can trigger export from within the AU extension (in any DAW or the host app).

**Deliverables:**
- [ ] "Export" toolbar button (next to existing preset controls)
  - Only enabled when a preset is loaded and user is licensed
  - Disabled with tooltip "License required" in demo mode
- [ ] Export confirmation sheet/popover:
  - Shows preset name (editable for the export)
  - Shows language (Python/Rust)
  - "Export" button
- [ ] Progress indicator during export (spinner in toolbar area)
- [ ] Post-export notification:
  - Success: "Exported! Open BearBone to install." or reveal in Finder
  - Error: display error message
- [ ] App Group setup:
  - Add App Group entitlement to both BearBone and BearBoneExtension
  - `ExportManager` writes to App Group container when sandboxed
- [ ] Host app handler: on launch, check App Group container for pending exports
  - Move to user-chosen location via NSSavePanel
  - Final code sign
  - Reveal in Finder
  - Clean up App Group container

**Key files to create/modify:**
- `BearBoneExtension/UI/ExportButton.swift` (or add to `PresetToolbar.swift`)
- `BearBoneExtension/UI/ExportSheet.swift`
- `BearBone/Model/PendingExportHandler.swift`
- Entitlements files (add App Group)

**Technical notes:**
- App Group identifier: `group.com.MichaelJancsy.BearBone`
- The extension writes the complete .app to `FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:)`
- Communication between extension and host app: simplest is just filesystem (host app polls or checks on launch). More sophisticated: `CFNotificationCenter` distributed notifications or `NSXPCConnection`
- The host app should show a "Pending exports" UI if it finds .app bundles in the App Group container on launch

### Phase 4: Python Support

**Goal:** Exported Python presets work with a shared Python runtime.

**Deliverables:**
- [ ] Shared Python runtime installer:
  - On first BearBone launch, copy `python-dist/lib/python3.14t/` to `~/Library/Application Support/BearBone/PythonRuntime-3.14/`
  - Skip if already exists (version check via marker file)
  - Progress indicator during copy (~80MB)
- [ ] Player AU Python support:
  - Add `libpython3.14t.dylib` bundling to the export pipeline (Phase 2 addition)
  - Player AU init: resolve PYTHONHOME via fallback chain (bundle → shared → env var)
  - Call `dsp_kernel_load_script()` with resolved paths
- [ ] Missing runtime error UI:
  - SwiftUI view shown when PYTHONHOME resolution fails
  - "Python runtime not found" message with explanation
  - "Install Runtime" button that downloads Python runtime from python-build-standalone
  - Download progress indicator
  - Auto-retry loading the script after successful install
- [ ] Runtime download manager:
  - Same logic as `setup-python.sh` but in Swift
  - Downloads python-build-standalone release
  - Extracts to `~/Library/Application Support/BearBone/PythonRuntime-3.14/`
  - Installs numpy via pip or bundles pre-built numpy

**Key files to create/modify:**
- `BearBonePlayerExtension/UI/RuntimeErrorView.swift`
- `BearBonePlayerExtension/RuntimeInstaller.swift` (or shared location)
- `BearBone/Model/SharedRuntimeManager.swift`

**Technical notes:**
- The dylib (~5-10MB) MUST be in each exported AU's Frameworks/ — dynamic linker needs it at load time regardless of PYTHONHOME
- `PYTHONHOME` only affects where Python finds its stdlib and site-packages
- The Rust kernel's `dsp_kernel_load_script()` already accepts a `python_home` parameter — just pass the resolved path
- numpy ABI compatibility: pin to a specific numpy version in the shared runtime. Document that runtime updates may break old exports
- The "Install Runtime" download in an exported AU needs network entitlement in the player extension

### Phase 5: Polish & Validation

**Goal:** Production-ready export experience.

**Deliverables:**
- [ ] Validation step: after export, attempt to instantiate the AU via `AVAudioUnit.instantiate` and verify it processes audio
- [ ] Export error recovery: if signing fails, if template is missing, etc.
- [ ] Parameter metadata in exported AU (future: custom names, ranges — v1 ships generic)
- [ ] Documentation:
  - User-facing: how to export, install, share, troubleshoot
  - Developer-facing: how the export pipeline works (for CLAUDE.md)
- [ ] Integration tests:
  - Export a WASM preset → load in simulated host → verify audio processing
  - Export a Python preset → load with shared runtime → verify audio processing
  - Export duplicate name → verify overwrite behavior
  - Export without license → verify blocked
- [ ] UI tests: export button visibility, license gating, progress indicator
- [ ] Edge cases:
  - Preset name with special characters (sanitize for bundle ID and filesystem)
  - Very long preset names (truncate for 4-char subtype, abbreviate for bundle)
  - Export while audio is processing (should work — export is async, doesn't affect render)

---

## Open Questions / Future Work

- **Parameter customization:** Let users name params, set ranges, choose count. Requires changes to the parameter tree in the exported AU. Deferred to post-v1.
- **Notarization pipeline:** For users who want to share exports. Would need either (a) user provides their own developer identity, or (b) BearBone notarizes on behalf (requires server infrastructure). Deferred.
- **Export UI enhancement:** v1 has minimal labeled sliders. Could add richer UI (knobs, visualizations) if parameter metadata is available.
- **Preset bundles:** Export multiple presets as a single AU with a preset selector. More complex, deferred.
- **Windows/Linux:** If BearBone ever goes cross-platform, the export concept could extend to VST3/CLAP. Very far future.

---

## Reference

- Design Q&A: `docs/export-au-questions.md`
- Backlog: `backlog.md` (Export AUv3 feature, 5 phases)
- Related existing code:
  - WASM compilation: `BearBoneExtension/Common/Audio Unit/RustCompiler.swift`, `WasmCache.swift`
  - Rust kernel FFI: `rust/bearbone_dsp/src/lib.rs`, `kernel.rs`
  - Python runtime setup: `rust/setup-python.sh`
  - AU identity patching: `scripts/patch-worktree-au-identity.sh` (similar plist patching needed for exports)
  - License system: `rust/bearbone_dsp/src/license.rs`, `BearBoneExtension/UI/LicenseManager.swift`
