# ConjureDSP

AUv3 audio effect plugin for macOS with embedded Python DSP scripting. Built with Apple's Audio Unit Extension framework.

## Build

Xcode project with a Rust build phase. Open `ConjureDSP.xcodeproj` or build from CLI:

```bash
xcodebuild -project ConjureDSP.xcodeproj -scheme ConjureDSP build
xcodebuild -project ConjureDSP.xcodeproj -scheme ConjureDSP test   # runs unit + UI tests
```

### Prerequisites
- Xcode with Swift 5.0+
- Rust toolchain (`rustup`, `cargo`) with target: `aarch64-apple-darwin`
- `cbindgen` (`cargo install cbindgen`)
- Bundled Python runtime (one-time setup): `cd rust && ./setup-python.sh`
- Bundled Rust compiler (one-time setup): `./scripts/setup-rustc.sh`
- Monaco Editor (one-time setup): `./scripts/setup-monaco.sh`

Deployment targets: macOS 26.2+.

### Python setup
Run `rust/setup-python.sh` once before the first build. This downloads a free-threaded Python 3.14 build from python-build-standalone (~100MB) and installs numpy and scipy into it. The result lives in `rust/python-dist/` (gitignored).

### Rust build
The `ConjureDSPExtension` target has a Run Script build phase that calls `rust/build-rust.sh`. This:
1. Sets `PYO3_PYTHON` to the bundled `rust/python-dist/bin/python3`
2. Builds the Rust static library (`libconjure_dsp.a`) via `cargo build`
3. Generates the C header (`rust/include/conjure_dsp.h`) via `cbindgen`

To build/test the Rust crate standalone: `cd rust && DYLD_LIBRARY_PATH="$(pwd)/python-dist/lib" PYO3_PYTHON="$(pwd)/python-dist/bin/python3" cargo test -- --test-threads=1`

Note: `--test-threads=1` is required because Python tests share a single interpreter and the module name `dsp_script` in `sys.modules`. `DYLD_LIBRARY_PATH` is needed because python-build-standalone reports its LIBDIR as `/install/lib` (build-time path); the `build.rs` handles link-time search paths but the dylib must be findable at runtime too.

### Xcode build phases (ConjureDSPExtension target)
1. **Run Script — Build Rust**: calls `rust/build-rust.sh`
2. **Run Script — Copy Python Runtime**: copies `libpython3.14t.dylib` into Frameworks, copies `python3.14t/` stdlib+numpy into Resources/python-dist, and code-signs the dylib and all `.so` files with `EXPANDED_CODE_SIGN_IDENTITY`
3. **Run Script — Copy Rust Compiler**: copies bundled `rustc`, `librustc_driver`, `rust-lld`, and wasm32-wasip1 sysroot into Resources/rustc-dist/, code-signs all executables and dylibs

### Xcode build phases (ConjureDSP host app target)
4. **Bust AU Cache**: calls `scripts/bust-au-cache.sh` — kills `AudioComponentRegistrar` so macOS re-discovers AU registrations after every build. Skipped during test actions to avoid interfering with the test runner.

## Architecture

- **Swift + SwiftUI** for all UI, host app logic, buffer management, and render block
- **Rust** for the DSP kernel, with pluggable backends for Python and WASM processing
- **Python** for user-editable DSP scripts, called each render callback with pre-allocated numpy arrays
- **Rust/WASM** as an alternative DSP language — Rust source compiled to WASM via bundled rustc, executed by wasmtime
- **C FFI** via bridging header (`ConjureDSPExtension-Bridging-Header.h`) imports `conjure_dsp.h`

### Multi-language DSP
Scripts can be written in Python (instant load) or Rust (compiled to WASM). `ScriptLanguage` auto-detects the language via heuristics (e.g., `fn process()` → Rust). `WasmCache` stores compiled WASM binaries by SHA256 hash to avoid redundant compilation. Both backends implement a common `Backend` trait with `initialize()`, `process()`, and metadata extraction.

### Python DSP pipeline
1. On AU init, Swift calls `dsp_kernel_load_script()` with the bundled `process.py` path and Python home
2. Rust sets `PYTHONHOME`, initializes the free-threaded Python 3.14 interpreter via pyo3, and caches the script's `process()` function
3. On `allocateRenderResources()`, Rust pre-allocates numpy float32 arrays (one per channel, sized to `maximumFramesToRender`)
4. Each render callback: Rust copies input audio into numpy arrays, calls `process(inputs, outputs, frame_count, sample_rate, params)`, copies output back. If PARAMS metadata exists, params is a dict of denormalized values; otherwise a list of 0–1 floats.
5. If Python fails to load or errors at runtime, Rust falls back to passthrough (copies input to output)

### WASM DSP pipeline
1. Rust source is compiled to `wasm32-wasip1` using a bundled standalone rustc (preferred for sandbox compatibility) or system rustc
2. wasmtime loads the WASM module with fuel metering for safety (prevents infinite loops)
3. I/O buffers are shared via WASM exports (`get_input_ptr`/`get_output_ptr`) or fixed memory offsets
4. Parameter metadata is extracted from `get_param_metadata_json`/`get_param_metadata_len` WASM exports

### Monaco Editor
The code editor uses Monaco Editor (VS Code's editor) loaded in a WKWebView. It auto-detects Python vs Rust, applies light/dark themes, and communicates with Swift via `WKUserContentController` message handlers. Downloaded by `scripts/setup-monaco.sh` to `Resources/monaco/vs/` (gitignored).

### AI Chat Sidebar
An in-plugin AI assistant powered by Anthropic's Claude API with SSE streaming. Exposes 9 tools the AI can invoke: `compile_and_run`, `get_script`, `get_error`, `set_parameter`, `get_parameters`, `get_audio_state`, `list_presets`, `save_preset`, and `toggle_bypass`. API keys stored in Keychain.

### GitHub Integration
Two workflows: **CommunityPresetStore** for browsing community presets via public GitHub search, and **PersonalRepoSync** for two-way sync with a user's private preset repository (PAT-based). Repos are validated via a `conjuredsp.json` marker file. Auto-syncs preset saves/deletes via callbacks into PresetManager.

### Spectrogram Visualization
Lock-free ring buffers (written by audio thread, read by UI) feed FFT computation via Accelerate/vDSP on the main thread (CADisplayLink-synced). Supports 4 modes: input, output, difference, and normalized difference. Log and linear frequency scales with diverging colormaps for difference modes.

### License System
Ed25519-based offline license verification. Licenses stored at `~/Library/Application Support/ConjureDSP/license.key`. Rust verifies signatures using an embedded public key and sets an atomic `licensed` flag for lock-free audio-thread checks. Demo mode allows 60 seconds of unlicensed processing before silencing output.

## Project Structure

```
ConjureDSP/                  Host app — loads and tests the AU extension
  Model/                     AudioUnitHostModel, AudioUnitViewModel, PendingExportHandler, SharedPythonRuntimeInstaller
  Common/Audio/              SimplePlayEngine (AVAudioEngine wrapper)
  Common/MIDI/               MIDIManager
  SentrySetup.swift          Sentry crash reporting initialization
  ValidationView.swift       Debug UI for AU validation output
ConjureDSPExtension/         The AU plugin itself
  AI/                        AI chat sidebar — AnthropicProvider, ChatTools (9 tools), ToolExecutor, SSEParser, KeychainHelper
  Analytics.swift            Mixpanel analytics wrapper
  Audio/                     AudioCaptureManager — reads ring buffers for spectrogram FFT
  Compilation/               RustCompiler (bundled rustc → WASM), ScriptCompiler, ScriptLanguage (auto-detect), WasmCache (SHA256)
  Export/                    ExportManager (standalone AUv3 pipeline), ExportRegistry, SubtypeGenerator
  GitHub/                    GitHubService, GitHubClient, CommunityPresetStore, PersonalRepoSync, GitHubModels
  Model/                     LicenseManager (Ed25519 + demo), Preset, PresetManager
  Parameters/                Parameter addresses (Swift enum)
  UI/                        MonacoEditorView, SpectrogramView, ChatSidebarView, CommunityBrowserView,
                             PresetBrowserView, ParameterSlidersView, GitHubSettingsView, ExportPopover, and more
  Resources/                 Factory presets (.py + .wasm), process.py, monaco/ (gitignored)
  Common/Audio Unit/         ConjureDSPExtensionAudioUnit.swift — AUAudioUnit subclass + render block
  Common/UI/                 AudioUnitViewController
  Common/Utility/            CrossPlatform.swift, SentrySetup.swift, String+Utils.swift
ConjureDSPExportAUTemplate/  Standalone export AU template project
  ConjureDSPExportAUTemplate/          Host app for template
  ConjureDSPExportAUTemplateExtension/ AU extension template
  ConjureDSPExportAUTemplateTests/     Template tests
  project.yml               XcodeGen project spec
rust/                        Rust DSP crate
  conjure_dsp/src/
    lib.rs                   C FFI entry points
    kernel.rs                DSPKernel — manages backends, parameters, license/demo state, ring buffers
    backend.rs               Backend trait (pluggable processing interface)
    python_backend.rs        pyo3-based Python 3.14 embedding, numpy array interop
    wasm_backend.rs          wasmtime-based WASM execution with fuel metering
    params.rs                ParamMetadata, denormalize/normalize with log curve support
    ring_buffer.rs           SPSC lock-free ring buffer (audio thread → UI)
    license.rs               Ed25519 license verification (embedded public key)
  test_plugin_dsp/           Test harness for standalone DSP testing
  include/                   Generated C header (conjure_dsp.h)
  build-rust.sh              Xcode build phase script
  setup-python.sh            Downloads free-threaded Python 3.14 + numpy + scipy
  setup-wasm-target.sh       Installs wasm32-wasip1 target for Rust compiler
  python-dist/               Bundled Python runtime (gitignored)
scripts/                     Build and setup scripts
  setup-rustc.sh             Downloads standalone Rust compiler for WASM compilation
  setup-monaco.sh            Downloads Monaco Editor for code editing UI
  stamp-build-id.sh          Stamps build ID into extension Info.plist
  bust-au-cache.sh           Kills AudioComponentRegistrar for fresh AU registration
  release.sh                 End-to-end release: archive, notarize, DMG
  build-release.sh           Archives Release configuration with Developer ID signing
  create-dmg.sh              Creates distributable DMG from signed .app
  notarize.sh                Submits to Apple notarization service
  upload-dsyms.sh            Uploads debug symbols to Sentry
  pre-build-clean.sh         Moves /Applications install out of DerivedData's way
  generate-test-serial.sh    Generates test license serial numbers
  backup-keypair.sh          Backs up Ed25519 license keypair
  restore-keypair.sh         Restores Ed25519 license keypair
  rebuild-and-copy-export-template.sh  Builds export AU template and copies into main app
assets/                      App icons (app-icon.png, export-icon.png)
tools/generate-license/      Rust CLI for generating license keys
plans/                       Implementation plans (ai-assisted-coding, host-app-daw-controls, etc.)
rustc-dist/                  Bundled Rust compiler + wasm32-wasip1 target (gitignored)
docs/                        Design docs (export-au-plan, python-package-management, preset-repo-format, etc.)
ConjureDSPTests/             Unit tests (Swift Testing)
ConjureDSPUITests/           UI tests (XCUITest)
```

## Parameter System

Up to 16 parameters, with optional rich metadata declared via `PARAMS` dict. Two modes:

**Rich metadata mode**: Scripts declare per-parameter metadata with name, min, max, unit, default, and optional `curve`. The AU parameter tree is rebuilt with real ranges. Scripts receive denormalized actual values. DAW/UI shows meaningful values with units. Both Python and Rust/WASM use the same system — parameters behave identically regardless of language.

Use `"curve": "log"` for frequency and wide-range time parameters (e.g., cutoff 20–20kHz, attack 0.5–50ms). Log mapping uses `min * (max/min)^t` so the slider feels natural across orders of magnitude. Default is linear.

Python:
```python
PARAMS = {
    "cutoff": {"min": 20, "max": 20000, "unit": "Hz", "default": 1000, "curve": "log"},
    "resonance": {"min": 0, "max": 1, "unit": "", "default": 0.5},
}
def process(inputs, outputs, frame_count, sample_rate, params):
    cutoff_hz = params["cutoff"]  # already 20–20000, log-mapped
```

Rust/WASM:
```rust
static METADATA: &str = r#"[
    {"name":"Cutoff","min":20,"max":20000,"unit":"Hz","default":1000,"curve":"log"},
    {"name":"Resonance","min":0,"max":1,"unit":"","default":0.5}
]"#;

#[unsafe(no_mangle)] pub extern "C" fn get_param_metadata_json() -> *const u8 { METADATA.as_ptr() }
#[unsafe(no_mangle)] pub extern "C" fn get_param_metadata_len() -> usize { METADATA.len() }

// PARAMS_BUF receives denormalized actual values when metadata exists
let cutoff_hz = PARAMS_BUF[CUTOFF];  // already 20–20000, log-mapped
```

**Legacy mode**: Scripts without metadata get raw 0–1 floats and generic AU parameters (backward compatible).

Implementation across layers:

1. **Rust** (`params.rs`) — `ParamMetadata` struct (name, key, min, max, default, unit, curve) with `denormalize()`/`normalize()` methods. `PARAM_COUNT = 16`
2. **Rust** (`python_backend.rs`) — Extracts `PARAMS` dict from Python module, builds `PyDict` with denormalized values for `process()`. Falls back to `PARAM_NAMES` dict or `PyList` of 0–1 floats.
3. **Rust** (`kernel.rs`) — Stores normalized 0–1 via `AtomicU32` array. Caches metadata as JSON. Sets defaults from metadata on script load.
4. **Rust** (`lib.rs`) — `dsp_kernel_param_metadata_json()` FFI returns metadata JSON to Swift.
5. **Swift** (`ConjureDSPExtensionAudioUnit.swift`) — `rebuildParameterTree(metadata:)` creates `AUParameter`s with real ranges. `implementorValueObserver` normalizes actual → 0–1 for kernel. `implementorValueProvider` denormalizes 0–1 → actual for DAW. `formatParamValue` displays values with units.
6. **WASM** (`wasm_backend.rs`) — Extracts metadata from `get_param_metadata_ptr`/`get_param_metadata_len` WASM exports. When metadata exists, WASM scripts receive denormalized actual values in `PARAMS_BUF` (same as Python). Two separate exports are used instead of a tuple return to avoid WASM multi-value return ABI issues with Rust's `extern "C"`.

Parameters are passed to Python scripts as a 5th argument (dict or list) and to WASM modules via `get_params_ptr()`.

**Known Logic Pro quirk:** On the master channel strip, Logic's "Automatic Smart Controls" layout has fewer knob slots than on regular channel strips, so some parameters may not get mapped to knobs. All parameters are still registered and automatable — this is a Logic Smart Controls grid limitation, not an AU bug.

## DSP Conventions

- The Rust kernel embeds free-threaded Python 3.14 (no GIL) via pyo3 and numpy
- Python `process()` is called each render callback with pre-allocated numpy arrays (no per-callback allocations)
- When no Python script is loaded or Python errors at runtime, Rust falls back to passthrough (copies input to output)
- Swift calls Rust via C FFI: `dsp_kernel_create()`, `dsp_kernel_process()`, `dsp_kernel_load_script()`, etc.
- Bypass copies input to output unchanged
- Event processing loop lives in Swift alongside the render block
- Errors from Rust/Python are passed to Swift via `dsp_kernel_last_error()` and logged with `os_log`

## Worktrees

Git worktrees (e.g. created by Claude Code) are missing `rust/python-dist/`, `rustc-dist/`, and `ConjureDSPExtension/Resources/monaco/vs/` since they're gitignored. The `build-rust.sh` script auto-symlinks `python-dist/` from the main worktree, and the "Copy Rust Compiler" build phase auto-symlinks `rustc-dist/` from the main worktree. Monaco must be set up independently in each worktree: `./scripts/setup-monaco.sh`. So `xcodebuild build` and `xcodebuild test` work automatically (after Monaco setup). For standalone `cargo test`, run the Xcode build first (to create the symlink) or manually: `ln -s /path/to/main/repo/rust/python-dist rust/python-dist`.

**After creating a worktree, always run `./scripts/setup-monaco.sh` immediately.** A `PostToolUse` hook in `.claude/settings.json` handles this automatically for the `EnterWorktree` tool, but if you create a worktree manually, run it yourself.

Debug and Release builds use different AU identities (see Plugin Identity section), so worktree builds in Debug configuration automatically get the debug identity without any special handling. The host app and tests read AU identity from the embedded extension's Info.plist at runtime.

## AU Registration Troubleshooting

### Dangerous commands — NEVER use

- **`pluginkit -r`** — Permanently removes an extension from PluginKit's registry. Despite Apple's documentation claiming this "cannot make permanent alterations," the removal persists across reboots, DerivedData deletion, AU cache clearing, app relaunches, and even `pluginkit -e default`. Recovery requires purging stale LaunchServices entries (see below). **There is no safe use case for `pluginkit -r` during development.**
- **`pluginkit -e ignore`** — Suppresses an extension's registration. If the build fails before a corresponding `pluginkit -e default` runs, the extension stays suppressed indefinitely. Avoid in build scripts.

### How AU extension registration works

1. **LaunchServices** tracks which apps exist and where they live on disk
2. **PluginKit (pkd)** discovers extensions embedded in LaunchServices-registered apps
3. **AudioComponentRegistrar** reads PluginKit's registry to make AUs available to hosts

Registration breaks when any layer has stale or corrupted state.

### Common failure: stale LaunchServices entries

Over time, LaunchServices accumulates entries from old DerivedData directories that no longer exist. If multiple stale entries claim the same bundle ID, PluginKit may fail to discover the extension even from a valid, freshly-built app. This is the most common cause of "AU component not found" errors, especially for the Release bundle ID (which was shared across Debug/Release builds before the bundle ID separation was added).

**Diagnosis:** Check if LaunchServices has stale entries:
```bash
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister
$LSREGISTER -dump | grep -B20 "identifier:.*com\.MichaelJancsy\.ConjureDSP$" | grep "path:"
```
If this shows paths to DerivedData directories that no longer exist, that's the problem.

### Recovery procedure

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

### Prevention

- **Never use `pluginkit -r` or `pluginkit -e ignore` in build scripts.** The post-build `bust-au-cache.sh` uses only `killall AudioComponentRegistrar` + `lsregister`, which are safe.
- **Move `/Applications/ConjureDSP.app` during development** if a production install exists — it shadows DerivedData builds via PluginKit. The pre-build script handles this automatically.
- **Periodically clean old DerivedData** — stale entries accumulate in LaunchServices and can cause registration conflicts: `ls ~/Library/Developer/Xcode/DerivedData/ConjureDSP-*`

### Useful diagnostic commands

- `pluginkit -mv -p com.apple.AudioUnit-UI` — list registered AU extensions with paths (look for `+` prefix = elected)
- `pluginkit -m | grep ConjureDSP` — search all protocols (not just AU)
- `auval -v aufx 0001 CONJ` — validate the Release AU component
- `auval -v aufx DBG1 CONJ` — validate the Debug AU component
- `codesign -v -vvv <path-to-app>` — verify code signing is valid
- `codesign -d --entitlements - <path-to-appex>` — inspect extension entitlements

## Code Signing

Bundled runtimes require proper code signing for the hardened runtime:
- **Python**: `libpython3.14t.dylib` and all `.so` files (numpy, stdlib extensions) — handled by "Copy Python Runtime" build phase
- **Rust compiler**: `rustc`, `librustc_driver-*.dylib`, `rust-lld`, `gcc-ld/wasm-ld` — handled by "Copy Rust Compiler" build phase

## Release Pipeline

Run `scripts/release.sh` to build, sign, notarize, and package a distributable DMG. The script orchestrates: `xcodebuild archive` → `xcodebuild -exportArchive` with Developer ID signing → notarize app → create DMG → notarize DMG → staple.

### Provisioning profiles

Developer ID provisioning profiles must be created on the Apple Developer portal for both bundle IDs (`com.MichaelJancsy.ConjureDSP` and `com.MichaelJancsy.ConjureDSP.ConjureDSPExtension`). After downloading, copy them with UUID-based filenames to `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`:

```bash
# Extract UUID and install properly
UUID=$(security cms -D -i <profile>.provisionprofile | grep -A1 UUID | tail -1 | sed 's/.*<string>//' | sed 's/<\/string>//')
cp <profile>.provisionprofile ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/${UUID}.provisionprofile
```

`ExportOptions.plist` uses `signingStyle: manual` with explicit profile name mappings, since automatic signing doesn't reliably find Developer ID profiles from CLI builds.

### Re-signing after export

`build-release.sh` modifies the exported app bundle (re-signs rustc-dist, export template) then re-signs the extension and host app. **Critical**: the re-sign must use `--preserve-metadata=entitlements`, NOT `--entitlements <file>`. The entitlements file only contains a subset; `xcodebuild -exportArchive` injects additional entitlements (`com.apple.application-identifier`, `com.apple.developer.team-identifier`, `com.apple.security.app-sandbox`, etc.) that pkd requires to discover the AU extension. If these are stripped, the extension silently fails to register — no errors in logs, just absent from `pluginkit -mv`.

### Entitlement pitfalls

- **Never add `inter-app-audio`** — it's deprecated and not covered by Developer ID provisioning profiles. macOS will SIGKILL the app on launch with `zsh: killed` (no useful error message).
- Hardened runtime exceptions (`allow-jit`, `allow-unsigned-executable-memory`) and sandbox entitlements (`network.client`, `files.user-selected.read-only`) are unrestricted for Developer ID and don't need profile coverage.

### Verifying a release build

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

If the extension doesn't register, check for stale LaunchServices entries (see AU Registration Troubleshooting). On a test machine, if the app was opened from the DMG volume before copying to `/Applications/`, unregister the stale `/Volumes/` path first:

```bash
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister
$LSREGISTER -u /Volumes/ConjureDSP/ConjureDSP.app 2>/dev/null
$LSREGISTER -f -R -trusted /Applications/ConjureDSP.app
killall -9 pkd AudioComponentRegistrar 2>/dev/null
```

## Dependencies

- **Apple frameworks**: AudioToolbox, AVFoundation, CoreAudioKit, CoreMIDI, SwiftUI, Combine
- **Swift packages**: Sentry (crash reporting), Mixpanel (analytics)
- **Rust crates**: pyo3 0.27 (Python embedding), numpy 0.27 (numpy array interop)
- **Bundled runtime**: Free-threaded Python 3.14.3 + numpy + scipy (downloaded via `setup-python.sh`)

## Plugin Identity

- Type: `aufx` (effect)
- Manufacturer: `CONJ`
- Subtype: `0001` (Release) / `DBG1` (Debug)

Debug and Release builds use different AU identities and bundle IDs so they can coexist without interfering:

| | Debug | Release |
|---|---|---|
| Host App Bundle ID | `com.MichaelJancsy.ConjureDSP.debug` | `com.MichaelJancsy.ConjureDSP` |
| Extension Bundle ID | `com.MichaelJancsy.ConjureDSP.debug.ConjureDSPExtension` | `com.MichaelJancsy.ConjureDSP.ConjureDSPExtension` |
| AU Subtype | `DBG1` | `0001` |
| AU Name | `Michael Jancsy: ConjureDSPExtension (Debug)` | `Michael Jancsy: ConjureDSPExtension` |

These are configured via per-configuration build settings (`CD_AU_SUBTYPE`, `CD_AU_NAME`, `PRODUCT_BUNDLE_IDENTIFIER`) in the pbxproj, referenced in `ConjureDSPExtension/Info.plist` via `$(VARIABLE)` substitution. Both the host app and extension use separate bundle IDs per configuration so PluginKit registers them independently — this prevents a Release build installed at `/Applications/` from shadowing the Debug extension during development.

## Export Preset as Standalone AUv3

Export ConjureDSP presets as standalone AUv3 plugins. Phases 1–4 complete; Phase 5 (polish & validation) remaining. Full implementation plan in `docs/export-au-plan.md`, design Q&A in `docs/export-au-questions.md`. Key points:
- Both Python (.py) and Rust (.wasm) presets exportable
- Pre-built template AU (`ConjureDSPExportAUTemplate/`) — copy, patch plist, inject preset, ad-hoc sign
- App Group container for sandbox-safe writes from DAW-hosted AU extension
- Shared Python runtime at `~/Library/Application Support/ConjureDSP/PythonRuntime-3.14/`
- Licensed users only can export; exported AUs run freely

## Backlog Management

At the start of every session, read `backlog.md` in the repo root. Always begin a session by reading backlog.md and briefly summarizing current status. At the end of every session (or when completing/starting features), update `backlog.md` to reflect:
- Newly completed features (move from "To Do" or "In Progress" to "Done" with the date)
- Any new feature requests or ideas that came up during the session
- Any items that moved to "In Progress"

Always keep `backlog.md` as the source of truth for project status.
