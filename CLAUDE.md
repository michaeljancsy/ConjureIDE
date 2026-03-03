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

## Architecture

- **Swift + SwiftUI** for all UI, host app logic, buffer management, and render block
- **Rust** for the DSP kernel, embedding Python via pyo3/numpy for scriptable processing
- **Python** for the user-editable DSP script (`process.py`), called each render callback with pre-allocated numpy arrays
- **C FFI** via bridging header (`BearBoneExtension-Bridging-Header.h`) imports `bearbone_dsp.h`

### Python DSP pipeline
1. On AU init, Swift calls `dsp_kernel_load_script()` with the bundled `process.py` path and Python home
2. Rust sets `PYTHONHOME`, initializes the free-threaded Python 3.14 interpreter via pyo3, and caches the script's `process()` function
3. On `allocateRenderResources()`, Rust pre-allocates numpy float32 arrays (one per channel, sized to `maximumFramesToRender`)
4. Each render callback: Rust copies input audio into numpy arrays, calls `process(inputs, outputs, frame_count, sample_rate)`, copies output back
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
  patch-worktree-au-identity.sh  Patches AU identity for worktree builds
rustc-dist/                  Bundled Rust compiler + wasm32-wasip1 target (gitignored)
BearBoneTests/             Unit tests (Swift Testing)
BearBoneUITests/           UI tests (XCUITest)
```

## Parameter System

No parameters are currently defined. The parameter infrastructure exists in:

1. **Rust** (`rust/bearbone_dsp/src/params.rs`) — parameter address constants
2. **Swift enum** (`Parameters.swift`) — `BearBoneExtensionParameterAddress`
3. **Rust kernel** (`rust/bearbone_dsp/src/kernel.rs`) — `set_parameter`/`get_parameter`

To add a new parameter, define its address in all three layers and keep them in sync.

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

Worktree builds automatically register a different AU identity so they can coexist with the main build in DAWs. The "Patch AU Identity for Worktree" build phase (`scripts/patch-worktree-au-identity.sh`) detects worktree builds and patches the extension's built Info.plist to use subtype `WT01` and name `BearBoneExtension (Dev)`. The host app and tests read AU identity from the embedded extension's Info.plist at runtime, so they automatically use the correct codes for both main and worktree builds.

## AU Registration Troubleshooting

**Avoid using `pluginkit -r`** to remove an AU extension registration during development. Although Apple's documentation says `pluginkit` options "cannot make permanent alterations of the automatic registry state" and the `pkd` daemon should re-discover extensions automatically, PluginKit re-registration can be unreliable in practice — extensions sometimes fail to re-register after removal, requiring manual recovery steps. Prefer `pluginkit -e ignore -i <bundle-id>` (and later `pluginkit -e default -i <bundle-id>` to restore) if you need to temporarily hide an extension.

**Recovery procedure** if an AU disappears from hosts:
1. Try re-launching the host app (PluginKit re-registers extensions when the parent app launches)
2. Kill the audio component registrar: `killall -9 AudioComponentRegistrar`
3. If still missing, delete DerivedData: `rm -rf ~/Library/Developer/Xcode/DerivedData/BearBone-*`
4. Clear the AU cache: `rm -f ~/Library/Caches/AudioUnitCache/com.apple.audiounits.cache`
5. Clean build: `xcodebuild -project BearBone.xcodeproj -scheme BearBone clean build`

The clean build into a fresh DerivedData directory gets a new UUID and re-registers with LaunchServices.

**Useful diagnostic commands:**
- `pluginkit -mv -p com.apple.AudioUnit-UI` — list registered AU extensions with paths
- `auval -v aufx 0001 A000` — validate the main AU component
- `auval -v aufx WT01 A000` — validate the worktree AU component

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
- Manufacturer: `A000`
- Subtype: `0001` (main repo), `WT01` (worktree builds)

## Backlog Management

At the start of every session, read `backlog.md` in the repo root. Always begin a session by reading backlog.md and briefly summarizing current status. At the end of every session (or when completing/starting features), update `backlog.md` to reflect:
- Newly completed features (move from "To Do" or "In Progress" to "Done" with the date)
- Any new feature requests or ideas that came up during the session
- Any items that moved to "In Progress"

Always keep `backlog.md` as the source of truth for project status.
