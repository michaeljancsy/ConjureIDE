# AUv3 Preset Export — Implementation Plan

Export a BearBone preset (Python or Rust) as a standalone AUv3 plugin that the user can install and use in any DAW without BearBone running.

## Key Decisions

| Decision | Choice |
|----------|--------|
| Exportable languages | Both: Python (.py source) and Rust (.wasm binary only) |
| Template app behavior | Richer info window (AU metadata, DAW instructions, Quit button) |
| Template location | Separate XcodeGen project (`BearBoneExportAUTemplate/`) |
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

### Phase 1: Template AU ✅ COMPLETE (2026-03-05)

**Goal:** A minimal AUv3 that loads a DSP preset from its own bundle Resources and processes audio. WASM-only initially.

**Implemented as:** `BearBoneExportAUTemplate/` — a separate XcodeGen-based project.

**Deliverables (all complete):**
- [x] Separate XcodeGen project: `BearBoneExportAUTemplate/project.yml` → generates `.xcodeproj`
  - Host app target (`BearBoneExportAUTemplate`) — info window with AU metadata, DAW instructions, Quit button
  - AU extension target (`BearBoneExportAUTemplateExtension`) — sandboxed appex
  - Unit test target (`BearBoneExportAUTemplateTests`) — 13 tests
- [x] Host app: richer info view showing AU name, type, subtype, manufacturer, version, DAW-specific hints
- [x] AU extension: `ExportAUAudioUnit` (AUAudioUnit subclass)
  - Loads `preset.wasm` from own bundle Resources via `dsp_kernel_load_wasm()`
  - Loads `runtime-config.json` for metadata (preset name, param count, param names)
  - Config-driven parameter tree (paramCount and paramNames from runtime-config.json)
  - Render block copied from main BearBone AU (same event processing, bypass, safety clamp)
  - Calls `dsp_kernel_set_licensed(kernel, true)` — no demo timer in exports
- [x] Minimal SwiftUI UI: preset name header, labeled sliders, "Made with BearBone" footer
- [x] Extension links same full `libbearbone_dsp.a` (with pyo3). Bundles `libpython3.14t.dylib` for linker resolution
- [x] Passthrough WASM preset compiled from `process.rs` included as placeholder
- [x] 13 unit tests: 4 Rust FFI (kernel lifecycle, bypass, params, licensing) + 9 AU component (instantiation, buses, channels, params, bypass, render lifecycle, WASM loading)

**Key files created:**
- `BearBoneExportAUTemplate/project.yml` — XcodeGen spec (3 targets + scheme)
- `BearBoneExportAUTemplate/BearBoneExportAUTemplate/` — host app (App.swift, InfoView.swift, AUInfo.swift)
- `BearBoneExportAUTemplate/BearBoneExportAUTemplateExtension/Audio Unit/ExportAUAudioUnit.swift`
- `BearBoneExportAUTemplate/BearBoneExportAUTemplateExtension/UI/` — ExportAUViewController, ExportAUMainView, ExportParameterState
- `BearBoneExportAUTemplate/BearBoneExportAUTemplateExtension/Model/RuntimeConfig.swift`
- `BearBoneExportAUTemplate/BearBoneExportAUTemplateExtension/Resources/` — preset.wasm, runtime-config.json
- `BearBoneExportAUTemplate/BearBoneExportAUTemplateTests/ExportAUTests.swift`

**Key build requirements discovered:**
- `ENABLE_APP_SANDBOX: YES` on extension target — required for PluginKit to register the AU
- `DEVELOPMENT_TEAM` + `CODE_SIGN_STYLE: Automatic` — proper code signing needed for AU registration
- `LD_RUNPATH_SEARCH_PATHS` must include `@loader_path/../Frameworks` on extension (for in-process loading)
- Test target needs `LD_RUNPATH_SEARCH_PATHS` to python-dist/lib and extension Frameworks
- XcodeGen `schemes:` section needed to include test target in Cmd+U

**Placeholder AU identity (patched at export time):**
- Type: `aufx`, Subtype: `TMPL`, Manufacturer: `A000`, Name: `BearBone: ExportTemplate`

### Phase 2: Export Pipeline ✅ COMPLETE (2026-03-05)

**Goal:** Given a preset (script source + compiled WASM if Rust), produce a working exported .app bundle.

**Implemented as:** `BearBoneExtension/Export/` — three files.

**Deliverables (all complete):**
- [x] `ExportManager` class with `exportPreset(name:, source:, wasmData:, language:, templateURL:, outputDirectory:) throws -> URL`
- [x] Pipeline steps:
  1. Locate template at provided `templateURL`
  2. Copy template to `outputDirectory/<SanitizedName>.app`
  3. Write preset file (`preset.py` or `preset.wasm`) into .appex Resources
  4. Generate `runtime-config.json` and write to .appex Resources
  5. Patch .app Info.plist: `CFBundleIdentifier`, `CFBundleName`, `CFBundleDisplayName`
  6. Patch .appex Info.plist: `CFBundleIdentifier`, AU subtype, AU name, AU description
  7. For Python: remove placeholder `preset.wasm` (libpython already in template)
  8. Ad-hoc code sign (deepest first: frameworks → appex → app) via `/usr/bin/codesign -s -`
  9. Register in ExportRegistry
  10. Return URL to the signed .app
- [x] `ExportRegistry` class: JSON file at `~/Library/Application Support/BearBone/export-registry.json`
- [x] `SubtypeGenerator`: SHA256 hash → 4-char alphanumeric code, collision + reserved code avoidance
- [x] 20 unit tests: 8 SubtypeGenerator + 6 ExportRegistry + 6 ExportManager (end-to-end with mock template)

**Key files created:**
- `BearBoneExtension/Export/ExportManager.swift`
- `BearBoneExtension/Export/ExportRegistry.swift`
- `BearBoneExtension/Export/SubtypeGenerator.swift`
- `BearBoneTests/ExportTests.swift` (+ test copies of Export files)

**Technical notes:**
- Template embedding deferred to Phase 3 — `ExportManager` accepts `templateURL` parameter
- Plist patching uses Foundation `PropertyListSerialization` (pure Swift, sandbox-compatible)
- Re-exporting same preset name reuses existing subtype from registry
- Code signing order: frameworks → appex → app (deepest first)

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
