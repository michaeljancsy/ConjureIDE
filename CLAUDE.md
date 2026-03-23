# BearBone

AUv3 audio effect plugin for macOS with embedded Python DSP scripting. Built with Apple's Audio Unit Extension framework.

## Build

Xcode project with a Rust build phase. Open `BearBone.xcodeproj` or build from CLI:

```bash
xcodebuild -project BearBone.xcodeproj -scheme BearBone build
xcodebuild -project BearBone.xcodeproj -scheme BearBone test   # runs unit + UI tests
```

### Prerequisites
- Xcode with Swift 5.0+
- Rust toolchain (`rustup`, `cargo`) with target: `aarch64-apple-darwin`
- `cbindgen` (`cargo install cbindgen`)
- Bundled Python runtime (one-time setup): `cd rust && ./setup-python.sh`
- Bundled Rust compiler (one-time setup): `./scripts/setup-rustc.sh`

Deployment targets: macOS 26.2+.

### Python setup
Run `rust/setup-python.sh` once before the first build. This downloads a free-threaded Python 3.14 build from python-build-standalone (~100MB) and installs numpy into it. The result lives in `rust/python-dist/` (gitignored).

### Rust build
The `BearBoneExtension` target has a Run Script build phase that calls `rust/build-rust.sh`. This:
1. Sets `PYO3_PYTHON` to the bundled `rust/python-dist/bin/python3`
2. Builds the Rust static library (`libbearbone_dsp.a`) via `cargo build`
3. Generates the C header (`rust/include/bearbone_dsp.h`) via `cbindgen`

To build/test the Rust crate standalone: `cd rust && DYLD_LIBRARY_PATH="$(pwd)/python-dist/lib" PYO3_PYTHON="$(pwd)/python-dist/bin/python3" cargo test -- --test-threads=1`

Note: `--test-threads=1` is required because Python tests share a single interpreter and the module name `dsp_script` in `sys.modules`. `DYLD_LIBRARY_PATH` is needed because python-build-standalone reports its LIBDIR as `/install/lib` (build-time path); the `build.rs` handles link-time search paths but the dylib must be findable at runtime too.

### Xcode build phases (BearBoneExtension target)
1. **Run Script — Build Rust**: calls `rust/build-rust.sh`
2. **Run Script — Copy Python Runtime**: copies `libpython3.14t.dylib` into Frameworks, copies `python3.14t/` stdlib+numpy into Resources/python-dist, and code-signs the dylib and all `.so` files with `EXPANDED_CODE_SIGN_IDENTITY`
3. **Run Script — Copy Rust Compiler**: copies bundled `rustc`, `librustc_driver`, `rust-lld`, and wasm32-wasip1 sysroot into Resources/rustc-dist/, code-signs all executables and dylibs

### Xcode build phases (BearBone host app target)
4. **Bust AU Cache**: calls `scripts/bust-au-cache.sh` — kills `AudioComponentRegistrar` so macOS re-discovers AU registrations after every build. Skipped during test actions to avoid interfering with the test runner.

## Architecture

- **Swift + SwiftUI** for all UI, host app logic, buffer management, and render block
- **Rust** for the DSP kernel, embedding Python via pyo3/numpy for scriptable processing
- **Python** for the user-editable DSP script (`process.py`), called each render callback with pre-allocated numpy arrays
- **C FFI** via bridging header (`BearBoneExtension-Bridging-Header.h`) imports `bearbone_dsp.h`

### Python DSP pipeline
1. On AU init, Swift calls `dsp_kernel_load_script()` with the bundled `process.py` path and Python home
2. Rust sets `PYTHONHOME`, initializes the free-threaded Python 3.14 interpreter via pyo3, and caches the script's `process()` function
3. On `allocateRenderResources()`, Rust pre-allocates numpy float32 arrays (one per channel, sized to `maximumFramesToRender`)
4. Each render callback: Rust copies input audio into numpy arrays, calls `process(inputs, outputs, frame_count, sample_rate, params)`, copies output back. If PARAMS metadata exists, params is a dict of denormalized values; otherwise a list of 0–1 floats.
5. If Python fails to load or errors at runtime, Rust falls back to passthrough (copies input to output)

## Project Structure

```
BearBone/                  Host app — loads and tests the AU extension
  Model/                     AudioUnitHostModel, AudioUnitViewModel
  Common/Audio/              SimplePlayEngine (AVAudioEngine wrapper)
  Common/MIDI/               MIDIManager
BearBoneExtension/         The AU plugin itself
  Parameters/                Parameter addresses (Swift enum)
  UI/                        SwiftUI views (MainView with Python script editor)
  Resources/process.py       Python DSP script (bundled into .appex)
  Common/Audio Unit/         BearBoneExtensionAudioUnit.swift — AUAudioUnit subclass + render block
  Common/UI/                 AudioUnitViewController
rust/                        Rust DSP crate
  bearbone_dsp/src/       kernel.rs (DSP+Python), lib.rs (FFI), params.rs (addresses)
  include/                   Generated C header (bearbone_dsp.h)
  build-rust.sh              Xcode build phase script
  setup-python.sh            Downloads free-threaded Python 3.14 + numpy
  python-dist/               Bundled Python runtime (gitignored)
scripts/                     Build and setup scripts
  setup-rustc.sh             Downloads standalone Rust compiler for WASM compilation
  stamp-build-id.sh          Stamps build ID into extension Info.plist
  bust-au-cache.sh           Kills AudioComponentRegistrar for fresh AU registration
rustc-dist/                  Bundled Rust compiler + wasm32-wasip1 target (gitignored)
BearBoneTests/             Unit tests (Swift Testing)
BearBoneUITests/           UI tests (XCUITest)
```

## Parameter System

Up to 16 parameters, with optional rich metadata declared via `PARAMS` dict. Two modes:

**Rich metadata mode** (new): Scripts declare a `PARAMS` dict with per-parameter name, min, max, unit, default. The AU parameter tree is rebuilt with real ranges. Python scripts receive a dict of actual values (`params["threshold"]` = -21.5 dB). DAW/UI shows meaningful values with units.

```python
PARAMS = {
    "threshold": {"min": -40, "max": -3, "unit": "dB", "default": -20},
    "ratio":     {"min": 2,   "max": 20, "unit": ":1", "default": 4},
}
def process(inputs, outputs, frame_count, sample_rate, params):
    threshold_db = params["threshold"]  # already -40 to -3, no mapping needed
```

**Legacy mode**: Scripts without `PARAMS` get a list of 0–1 floats and generic AU parameters (backward compatible).

Implementation across layers:

1. **Rust** (`params.rs`) — `ParamMetadata` struct (name, key, min, max, default, unit), `PARAM_COUNT = 16`
2. **Rust** (`python_backend.rs`) — Extracts `PARAMS` dict from Python module, builds `PyDict` with denormalized values for `process()`. Falls back to `PARAM_NAMES` dict or `PyList` of 0–1 floats.
3. **Rust** (`kernel.rs`) — Stores normalized 0–1 via `AtomicU32` array. Caches metadata as JSON. Sets defaults from metadata on script load.
4. **Rust** (`lib.rs`) — `dsp_kernel_param_metadata_json()` FFI returns metadata JSON to Swift.
5. **Swift** (`BearBoneExtensionAudioUnit.swift`) — `rebuildParameterTree(metadata:)` creates `AUParameter`s with real ranges. `implementorValueObserver` normalizes actual → 0–1 for kernel. `implementorValueProvider` denormalizes 0–1 → actual for DAW. `formatParamValue` displays values with units.
6. **WASM** (`wasm_backend.rs`) — Extracts metadata from `get_param_metadata_json` WASM export. WASM scripts still receive raw 0–1 in `PARAMS_BUF` (mapping compiled in).

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

Git worktrees (e.g. created by Claude Code) are missing `rust/python-dist/` and `rustc-dist/` since they're gitignored. The `build-rust.sh` script auto-symlinks `python-dist/` from the main worktree, and the "Copy Rust Compiler" build phase auto-symlinks `rustc-dist/` from the main worktree. So `xcodebuild build` and `xcodebuild test` work automatically. For standalone `cargo test`, run the Xcode build first (to create the symlink) or manually: `ln -s /path/to/main/repo/rust/python-dist rust/python-dist`.

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
$LSREGISTER -dump | grep -B20 "identifier:.*com\.MichaelJancsy\.BearBone$" | grep "path:"
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

# Unregister ALL stale BearBone entries from LaunchServices
$LSREGISTER -dump | grep -B20 "identifier:.*com\.MichaelJancsy\.BearBone" | grep "path:" | sed 's/.*path:[[:space:]]*//' | sed 's/ (0x.*//' | while read -r path; do
    echo "Unregistering: $path"
    $LSREGISTER -u "$path" 2>/dev/null
done

# Re-register ONLY the current build
$LSREGISTER -f -R -trusted ~/Library/Developer/Xcode/DerivedData/BearBone-*/Build/Products/Release/BearBone.app
$LSREGISTER -f -R -trusted ~/Library/Developer/Xcode/DerivedData/BearBone-*/Build/Products/Debug/BearBone.app

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
/usr/libexec/PlistBuddy -c "Set :data:com.MichaelJancsy.BearBone.BearBoneExtension:election 1" <path-to-Annotations>
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
- **Move `/Applications/BearBone.app` during development** if a production install exists — it shadows DerivedData builds via PluginKit. The pre-build script handles this automatically.
- **Periodically clean old DerivedData** — stale entries accumulate in LaunchServices and can cause registration conflicts: `ls ~/Library/Developer/Xcode/DerivedData/BearBone-*`

### Useful diagnostic commands

- `pluginkit -mv -p com.apple.AudioUnit-UI` — list registered AU extensions with paths (look for `+` prefix = elected)
- `pluginkit -m | grep BearBone` — search all protocols (not just AU)
- `auval -v aufx 0001 BEAR` — validate the Release AU component
- `auval -v aufx DBG1 BEAR` — validate the Debug AU component
- `codesign -v -vvv <path-to-app>` — verify code signing is valid
- `codesign -d --entitlements - <path-to-appex>` — inspect extension entitlements

## Code Signing

Bundled runtimes require proper code signing for the hardened runtime:
- **Python**: `libpython3.14t.dylib` and all `.so` files (numpy, stdlib extensions) — handled by "Copy Python Runtime" build phase
- **Rust compiler**: `rustc`, `librustc_driver-*.dylib`, `rust-lld`, `gcc-ld/wasm-ld` — handled by "Copy Rust Compiler" build phase

## Dependencies

- **Apple frameworks**: AudioToolbox, AVFoundation, CoreAudioKit, CoreMIDI, SwiftUI, Combine
- **Rust crates**: pyo3 0.27 (Python embedding), numpy 0.27 (numpy array interop)
- **Bundled runtime**: Free-threaded Python 3.14.3 + numpy (downloaded via `setup-python.sh`)

## Plugin Identity

- Type: `aufx` (effect)
- Manufacturer: `BEAR`
- Subtype: `0001` (Release) / `DBG1` (Debug)

Debug and Release builds use different AU identities and bundle IDs so they can coexist without interfering:

| | Debug | Release |
|---|---|---|
| Host App Bundle ID | `com.MichaelJancsy.BearBone.debug` | `com.MichaelJancsy.BearBone` |
| Extension Bundle ID | `com.MichaelJancsy.BearBone.debug.BearBoneExtension` | `com.MichaelJancsy.BearBone.BearBoneExtension` |
| AU Subtype | `DBG1` | `0001` |
| AU Name | `Michael Jancsy: BearBoneExtension (Debug)` | `Michael Jancsy: BearBoneExtension` |

These are configured via per-configuration build settings (`BB_AU_SUBTYPE`, `BB_AU_NAME`, `PRODUCT_BUNDLE_IDENTIFIER`) in the pbxproj, referenced in `BearBoneExtension/Info.plist` via `$(VARIABLE)` substitution. Both the host app and extension use separate bundle IDs per configuration so PluginKit registers them independently — this prevents a Release build installed at `/Applications/` from shadowing the Debug extension during development.

## Export Preset as Standalone AUv3

Planned feature to export BearBone presets as standalone AUv3 plugins. Full implementation plan in `docs/export-au-plan.md`, design Q&A in `docs/export-au-questions.md`. Key points:
- Both Python (.py) and Rust (.wasm) presets exportable
- Pre-built template AU (no xcodebuild at export time) — copy, patch plist, inject preset, ad-hoc sign
- App Group container for sandbox-safe writes from DAW-hosted AU extension
- Shared Python runtime at `~/Library/Application Support/BearBone/PythonRuntime-3.14/`
- Licensed users only can export; exported AUs run freely
- 5 implementation phases (see `docs/export-au-plan.md`)

## Backlog Management

At the start of every session, read `backlog.md` in the repo root. Always begin a session by reading backlog.md and briefly summarizing current status. At the end of every session (or when completing/starting features), update `backlog.md` to reflect:
- Newly completed features (move from "To Do" or "In Progress" to "Done" with the date)
- Any new feature requests or ideas that came up during the session
- Any items that moved to "In Progress"

Always keep `backlog.md` as the source of truth for project status.
