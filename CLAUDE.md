# ConjureDSP

AUv3 audio effect plugin for macOS with embedded Python DSP scripting. Built with Apple's Audio Unit Extension framework.

## Build

Xcode project with a Rust build phase. Open `ConjureDSP.xcodeproj` or build from CLI:

```bash
xcodebuild -project ConjureDSP.xcodeproj -scheme ConjureDSP build
xcodebuild -project ConjureDSP.xcodeproj -scheme ConjureDSP test   # runs unit + UI tests
```

### Testing

There are three test targets, from fastest to slowest:

1. **`ConjureDSPLogicTests`** — pure logic/FFI tests that run without launching the host app (~6s). **Use this by default.**
2. **`ConjureDSPTests`** — integration tests that require the host app (AU instantiation, factory presets, export integration). Launches `ConjureDSP.app` via `TEST_HOST` (~137s).
3. **`ConjureDSPUITests`** — UI automation tests. Slow. Only run when directly relevant to recent changes, and only the specific class/method.

```bash
# Logic tests only (default — fast, no app launch)
xcodebuild -project ConjureDSP.xcodeproj -scheme ConjureDSP test -only-testing:ConjureDSPLogicTests

# Host integration tests (launches the app)
xcodebuild -project ConjureDSP.xcodeproj -scheme ConjureDSP test -only-testing:ConjureDSPTests

# Both unit test targets
xcodebuild -project ConjureDSP.xcodeproj -scheme ConjureDSP test -only-testing:ConjureDSPLogicTests -only-testing:ConjureDSPTests

# Specific UI test class
xcodebuild -project ConjureDSP.xcodeproj -scheme ConjureDSP test -only-testing:ConjureDSPUITests/ConjureDSPUITests

# Specific UI test method
xcodebuild -project ConjureDSP.xcodeproj -scheme ConjureDSP test -only-testing:ConjureDSPUITests/LicenseUITests/testLicenseActivationUI
```

UI test classes and what they cover:
- `ConjureDSPUITests` — script editor, run button, preset toolbar, save button, build ID label, parameter sliders panel, typing in editor
- `LicenseUITests` — license activation flow, invalid serial error, activate button state
- `ConjureDSPUITestsLaunchTests` — app launch screenshot

### Prerequisites
- Xcode with Swift 5.0+
- Rust toolchain (`rustup`, `cargo`) with target: `aarch64-apple-darwin`
- `cbindgen` (`cargo install cbindgen`)
- Bundled Python runtime (one-time setup): `cd rust && ./setup-python.sh`
- Bundled Rust compiler (one-time setup): `./scripts/setup-rustc.sh`
- Monaco Editor (one-time setup): `./scripts/setup-monaco.sh`
- xterm.js terminal (one-time setup): `./scripts/setup-xterm.sh`
- Bundled uv package manager (one-time setup): `./scripts/setup-uv.sh`

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
2. **Run Script — Copy Python Dylib**: copies `libpython3.14t.dylib` into Frameworks and code-signs it. The Python stdlib is not bundled in the extension — it lives in the App Group container, provisioned by ConjureDSPTerminal.
3. **Run Script — Copy Rust Compiler**: copies bundled `rustc`, `librustc_driver`, `rust-lld`, and wasm32-wasip1 sysroot into Resources/rustc-dist/, code-signs all executables and dylibs

### Xcode build phases (ConjureDSP host app target)
4. **Bust AU Cache**: calls `scripts/bust-au-cache.sh` — kills `AudioComponentRegistrar` so macOS re-discovers AU registrations after every build. Skipped during test actions to avoid interfering with the test runner.

## Architecture

**The host app is primarily a development convenience, and all essential functionality must live in the extension.** The plugin must work fully when hosted in any DAW — the host app provides no runtime services to the extension. Any feature that requires the host app to be running (e.g., a server, a process manager) will not work in production DAW contexts.

- **Swift + SwiftUI** for all UI, host app logic, buffer management, and render block
- **Rust** for the DSP kernel, with pluggable backends for Python and WASM processing
- **Python** for user-editable DSP scripts, called each render callback with pre-allocated numpy arrays
- **Rust/WASM** as an alternative DSP language — Rust source compiled to WASM via bundled rustc, executed by wasmtime
- **C FFI** via bridging header (`ConjureDSPExtension-Bridging-Header.h`) imports `conjure_dsp.h`

### Multi-language DSP
Scripts can be written in Python (instant load) or Rust (compiled to WASM). `ScriptLanguage` auto-detects the language via heuristics (e.g., `fn process()` → Rust). `WasmCache` stores compiled WASM binaries by SHA256 hash to avoid redundant compilation. Both backends implement a common `Backend` trait with `initialize()`, `process()`, and metadata extraction.

### Python DSP pipeline
1. On AU init, Swift calls `dsp_kernel_load_script()` with the default preset path and Python home (resolved from the App Group container, provisioned by ConjureDSPTerminal)
2. Rust sets `PYTHONHOME`, initializes the free-threaded Python 3.14 interpreter via pyo3, and caches the script's `process()` function
3. On `allocateRenderResources()`, Rust pre-allocates numpy float32 arrays (one per channel, sized to `maximumFramesToRender`)
4. Each render callback: Rust copies input audio into numpy arrays, calls `process(inputs, outputs, frame_count, sample_rate, params)`, copies output back. If PARAMS metadata exists, params is a dict of denormalized values; otherwise a list of 0–1 floats.
5. If Python fails to load or errors at runtime, Rust falls back to passthrough (copies input to output)

### WASM DSP pipeline
1. Rust source is compiled to `wasm32-wasip1` using a bundled standalone rustc (preferred for sandbox compatibility) or system rustc
2. wasmtime loads the WASM module with fuel metering for safety (prevents infinite loops)
3. I/O buffers are shared via WASM exports (`get_input_ptr`/`get_output_ptr`) or fixed memory offsets
4. Parameter metadata is extracted from `get_param_metadata_json`/`get_param_metadata_len` WASM exports

### conjuredsp Libraries (Python + Rust)
Both Python and Rust DSP scripts can use a `conjuredsp` library that provides DSP building blocks and eliminates boilerplate. The two libraries have equivalent APIs:

**Python** (`rust/conjuredsp/`): Installed into bundled Python's site-packages by `setup-python.sh`. User scripts `from conjuredsp import freq, db, ...`.

**Rust** (`rust/conjuredsp-rs/`): Compiled to an rlib for `wasm32-wasip1` by `setup-rustc.sh` (or auto-rebuilt during the "Copy Rust Compiler" Xcode build phase). Bundled at `rustc-dist/lib/libconjuredsp.rlib`. `RustCompiler.swift` passes `--extern conjuredsp=<path>` to rustc. User scripts `use conjuredsp::*;`.

Rust API overview:
- `setup!()` — declares INPUT/OUTPUT/PARAMS/TRANSPORT buffers, MAX_CH/MAX_FR, get_*_ptr exports, ctx() helper
- `params! { NAME = builder() }` — generates parameter index constants + METADATA JSON at compile time
- Parameter builders: `freq()`, `db()`, `time_ms()`, `mix()`, `pct()`, `toggle()`, `ratio()`, `param(min, max)` — all support `.min()`, `.max()`, `.default()`, `.unit()`, `.curve()` modifiers
- `ctx()` — safe buffer access: `ctx.input(ch, frame)`, `ctx.set_output(ch, frame, val)`, `ctx.param(INDEX)`
- DSP utils: `db_to_gain`, `gain_to_db`, `smooth_coeff`, `ms_to_samples`, `soft_clip`, `lerp`, `crossfade`
- `BiquadCoeffs` (8 filter types) + `Biquad` (stateful DF2T), `DelayLine<SIZE>`, `Lfo` + `Waveform`
- `accel` module — hardware-accelerated vectorized math (Rust: `use conjuredsp::accel;`, Python: `from conjuredsp.accel import ...`). Functions: `matmul`, `vec_add`, `vec_mul`, `vec_tanh`, `vec_sigmoid`, `vec_add_scalar`. In WASM, these call Accelerate framework (vDSP/vecLib) via host imports for near-native performance. In Python, they wrap numpy. Used internally by NAM inference but available to any preset.

### Monaco Editor
The code editor uses Monaco Editor (VS Code's editor) loaded in a WKWebView. It auto-detects Python vs Rust, applies light/dark themes, and communicates with Swift via `WKUserContentController` message handlers. Downloaded by `scripts/setup-monaco.sh` to `Resources/monaco/vs/` (gitignored).

### Claude Code Terminal
An in-plugin terminal running Claude Code CLI via a companion app architecture. The AU extension runs an MCP server (HTTP, direct AU access) exposing 12 tools: `compile_and_run`, `get_script`, `get_error`, `set_parameter`, `get_parameters`, `get_audio_state`, `list_presets`, `save_preset`, `toggle_bypass`, `get_docs`, `list_packages`, and `list_tones`. The terminal UI uses xterm.js in a WKWebView with a contentEditable input proxy for keyboard input through the AU ViewBridge.

**ConjureDSPTerminal** is a companion app that runs the Claude Code CLI process (PTY) and WebSocket relay outside the AU extension sandbox. The extension cannot fork external binaries due to sandbox restrictions. Communication uses the App Group container for port discovery and lifecycle signaling. The companion app detects AU restarts via MCP port changes and health checks.

Setup: `scripts/setup-xterm.sh` downloads xterm.js to `Resources/terminal/xterm/` (gitignored).

### Git-backed preset library
The user presets directory (`<AppGroup>/Presets/`) is a real git repository, initialized on first launch. Every explicit Save / Save As / Delete / Rename triggers a commit. Users can optionally configure a GitHub (or any HTTPS) remote URL, and pushes fire automatically after commits (2 s trailing-edge debounce) or via a "Push now" button.

Architecture:
- **`ConjureDSPExtension/Git/PresetGitCoordinator.swift`** — `@Observable @MainActor` orchestrator. Owns the commit-message preference (`alwaysPrompt` vs `alwaysTimestamp`, backed by UserDefaults) and the remote URL. Entry points: `initIfNeeded()`, `recordSave/Delete/Rename`, `setRemote/clearRemote`, `pushIfRemoteConfigured()`.
- **`ConjureDSPExtension/Git/GitQueueClient.swift`** — thin async transport that writes a JSON request into `<AppGroup>/git-queue/requests/` and polls `<AppGroup>/git-queue/results/` for the matching response. 15 s timeout for most ops, 60 s for push.
- **`ConjureDSPExtension/Git/GitRequest.swift`** — shared JSON shapes for the queue (the terminal has an equivalent copy inline in `GitWorker.swift`, same pattern as `PackageInstallManager` ↔ `PackageInstaller`).
- **`ConjureDSPTerminal/GitWorker.swift`** — shells out to system `git` (resolved via `xcrun -f git` → `/usr/bin/git` → `which git`). Supports `initIfNeeded`, `commit`, `status`, `setRemote`, `removeRemote`, `push`, `remoteInfo`. Runs on the terminal's existing 500 ms reconcile loop alongside `PackageInstaller`/`CrateInstaller`/`ExportFinalizer`.

Push auth: the extension's Keychain-backed PAT is passed via a short-lived 0600 token file in the App Group container; the worker consumes it via an inline git credential helper (`!f() { echo username=x-access-token; echo "password=$(cat $tokenFile)"; }; f`) and unlinks it immediately after spawning git. Backlog item tracks switching to a stdin `GIT_ASKPASS` pipe for belt-and-suspenders.

Commit-message UX: `SaveAsPopover` shows an inline "Commit message" field when mode is `.alwaysPrompt`, pre-filled with `Add <name>`. The Save toolbar button opens `SaveMessagePopover` with `Update <name>` pre-filled. Either popover has a "Don't ask again — always use timestamp" link that flips the preference. Settings (`RemoteSyncSettingsView`) exposes a radio picker + "Reset to default".

Fail-open: if the terminal is down when a save happens, the request queues on disk and drains whenever the terminal next comes up. The preset file still saves locally. Push failures surface inline in Settings with a "Push failed: …" badge.

`GitHubService` is now minimal — just Keychain-backed PAT + remote URL persistence. `GitHubURLResolver` is a small helper for the "Import from URL" popover (GitHub web URL → raw URL rewrite + fetch); unrelated to preset history.

### Spectrogram Visualization
Lock-free ring buffers (written by audio thread, read by UI) feed FFT computation via Accelerate/vDSP on the main thread (CADisplayLink-synced). Supports 4 modes: input, output, difference, and normalized difference. Log and linear frequency scales with diverging colormaps for difference modes.

### Subscription System
Paddle Billing subscription model with a Cloudflare Workers backend (`server/`). The server issues Ed25519-signed time-limited tokens on subscription activation and refresh. The app verifies tokens locally (offline OK for up to 7 days grace period) using an embedded public key. Tokens stored in the App Group container (`group.com.MichaelJancsy.ConjureDSP`) shared between host app and AU extension. `SubscriptionManager.swift` handles periodic server refresh (6h when active, 1h during grace). Demo mode allows 60 seconds of unlicensed processing before silencing output. The `AtomicBool` licensed flag on the audio thread is set by `SubscriptionStatus` — Active and GracePeriod grant access, everything else falls back to demo.

## Project Structure

```
ConjureDSP/                  Host app — loads and tests the AU extension
  Model/                     AudioUnitHostModel, AudioUnitViewModel, PendingExportHandler
  Common/Audio/              SimplePlayEngine (AVAudioEngine wrapper)
  Common/MIDI/               MIDIManager
  SentrySetup.swift          Sentry crash reporting initialization
  ValidationView.swift       Debug UI for AU validation output
ConjureDSPExtension/         The AU plugin itself
  Terminal/                  MCPServer (HTTP+JSON-RPC), MCPProtocol (9 tools), TerminalServer (lifecycle)
  Analytics.swift            Mixpanel analytics wrapper
  Audio/                     AudioCaptureManager — reads ring buffers for spectrogram FFT
  Compilation/               RustCompiler (bundled rustc → WASM), ScriptCompiler, ScriptLanguage (auto-detect), WasmCache (SHA256)
  Export/                    ExportManager (standalone AUv3 pipeline), ExportRegistry, SubtypeGenerator
  Git/                       PresetGitCoordinator, GitQueueClient, GitRequest — orchestrates git-backed preset history
  GitHub/                    GitHubService (PAT + remote URL), GitHubURLResolver (URL import helper)
  Model/                     SubscriptionManager (token verification + server refresh), SubscriptionAPI (server comms), Preset, PresetManager
  Parameters/                Parameter addresses (Swift enum)
  UI/                        MonacoEditorView, SpectrogramView, TerminalView,
                             PresetBrowserView, ParameterSlidersView, RemoteSyncSettingsView (in GitHubSettingsView.swift),
                             SaveAsPopover, SaveMessagePopover, ExportPopover, and more
  Resources/                 Factory presets (.py + .wasm), process.py, monaco/ (gitignored)
  Common/Audio Unit/         ConjureDSPExtensionAudioUnit.swift — AUAudioUnit subclass + render block
  Common/UI/                 AudioUnitViewController
  Common/Utility/            CrossPlatform.swift, SentrySetup.swift, String+Utils.swift, KeychainHelper.swift
ConjureDSPTerminal/          Companion app — runs Claude Code CLI outside sandbox
  ConjureDSPTerminalApp.swift  App entry point, TerminalAppServer (lifecycle, health checks)
  PTYManager.swift           forkpty + execve for Claude Code, MCP config writing
  WebSocketServer.swift      NWListener WebSocket relay (PTY I/O → xterm.js)
  GitWorker.swift            Shells out to system git for the preset-library repo (init, commit, status, push, remote)
  PackageInstaller.swift     uv-backed Python package install/uninstall
  CrateInstaller.swift       cargo-backed Rust crate compile to wasm32-wasip1 rlib
  ExportFinalizer.swift      Finishes standalone AUv3 exports (signing, LaunchServices registration)
ConjureDSPHelper/            Deprecated stub target (replaced by ConjureDSPTerminal)
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
    license.rs               Ed25519 token verification + subscription status (embedded server public key)
  test_plugin_dsp/           Test harness for standalone DSP testing
  include/                   Generated C header (conjure_dsp.h)
  build-rust.sh              Xcode build phase script
  setup-python.sh            Downloads free-threaded Python 3.14 + numpy + scipy
  setup-wasm-target.sh       Installs wasm32-wasip1 target for Rust compiler
  conjuredsp/                Python DSP library (installed into bundled Python site-packages)
  conjuredsp-rs/             Rust DSP library (compiled to rlib for wasm32-wasip1)
    src/lib.rs               setup!(), params!() macros, re-exports
    src/dsp.rs               db_to_gain, smooth_coeff, soft_clip, lerp, crossfade
    src/filters.rs           BiquadCoeffs (8 filter types) + Biquad (stateful DF2T)
    src/buffers.rs           DelayLine<SIZE> with linear/cubic interpolation
    src/osc.rs               Lfo + Waveform enum + waveform functions
    src/params.rs            ParamSpec struct + const fn builders (freq, db, time_ms, etc.)
    src/json.rs              Const-fn JSON serialization for compile-time metadata
    src/context.rs           Context struct for safe buffer access
  python-dist/               Bundled Python runtime (gitignored)
server/                      Cloudflare Workers subscription API (D1 SQLite, Paddle webhooks, Ed25519 token signing)
scripts/                     Build and setup scripts
  setup-rustc.sh             Downloads standalone Rust compiler for WASM compilation
  setup-monaco.sh            Downloads Monaco Editor for code editing UI
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
  setup-xterm.sh             Downloads xterm.js for terminal UI
assets/                      App icons (app-icon.png, export-icon.png)
tools/generate-license/      Rust CLI for generating license keys
plans/                       Implementation plans (ai-assisted-coding, host-app-daw-controls, etc.)
rustc-dist/                  Bundled Rust compiler + wasm32-wasip1 target (gitignored)
docs/                        Design docs (export-au-plan, python-package-management, preset-repo-format, etc.)
ConjureDSPLogicTests/        Pure logic/FFI unit tests — no host app launch (Swift Testing)
ConjureDSPTests/             Integration tests requiring host app — AU, presets, exports (Swift Testing)
ConjureDSPUITests/           UI tests (XCUITest)
```

## Parameter System

Up to 16 parameters, with optional rich metadata declared via `PARAMS` dict. Two modes:

**Rich metadata mode**: Scripts declare per-parameter metadata with name, min, max, unit, default, and optional `curve`. The AU parameter tree is rebuilt with real ranges. Scripts receive denormalized actual values. DAW/UI shows meaningful values with units. Both Python and Rust/WASM use the same system — parameters behave identically regardless of language.

Use `"curve": "log"` for frequency and wide-range time parameters (e.g., cutoff 20–20kHz, attack 0.5–50ms). Log mapping uses `min * (max/min)^t` so the slider feels natural across orders of magnitude. Default is linear.

Use `"style": "toggle"` for on/off parameters (renders as a switch in the UI, `AUParameterUnit.boolean` for DAWs). Use `"style": "choice"` with `"options": ["A", "B", "C"]` for enum parameters (renders as a dropdown menu, `AUParameterUnit.indexed` with `valueStrings` for DAWs). Scripts receive the selected index as a float (0.0, 1.0, 2.0...). Default style is `"slider"`.

Python:
```python
from conjuredsp import freq, toggle, choice

PARAMS = {
    "cutoff": freq(),                                    # slider with log curve
    "bypass_eq": toggle(),                               # switch UI, 0.0 or 1.0
    "mode": choice("Low", "Mid", "High", default="Mid"), # dropdown, index as float
}
def process(inputs, outputs, frame_count, sample_rate, params):
    cutoff_hz = params["cutoff"]      # already 20–20000, log-mapped
    if params["bypass_eq"] >= 0.5:    # toggle is 0.0 or 1.0
        ...
    mode = int(params["mode"])        # 0, 1, or 2
```

Rust/WASM:
```rust
static METADATA: &str = r#"[
    {"name":"Cutoff","min":20,"max":20000,"unit":"Hz","default":1000,"curve":"log"},
    {"name":"Bypass EQ","min":0,"max":1,"default":0,"unit":"","style":"toggle"},
    {"name":"Mode","min":0,"max":2,"default":1,"unit":"","style":"choice","options":["Low","Mid","High"]}
]"#;

#[unsafe(no_mangle)] pub extern "C" fn get_param_metadata_json() -> *const u8 { METADATA.as_ptr() }
#[unsafe(no_mangle)] pub extern "C" fn get_param_metadata_len() -> usize { METADATA.len() }

// PARAMS_BUF receives denormalized actual values when metadata exists
let cutoff_hz = PARAMS_BUF[CUTOFF];  // already 20–20000, log-mapped
let bypass = PARAMS_BUF[BYPASS] >= 0.5;  // toggle: true/false
let mode = PARAMS_BUF[MODE] as usize;    // choice: 0, 1, or 2
```

**Legacy mode**: Scripts without metadata get raw 0–1 floats and generic AU parameters (backward compatible).

Implementation across layers:

1. **Rust** (`params.rs`) — `ParamMetadata` struct (name, key, min, max, default, unit, curve, style, options) with `denormalize()`/`normalize()` methods. `PARAM_COUNT = 16`
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
- Scripts that introduce algorithmic latency (lookahead, FFT, oversampling) declare `LATENCY = <samples>` (Python) or `latency!(<samples>)` (Rust). The AU reports this to the DAW via `AUAudioUnit.latency` for delay compensation. Scripts should only report real latency (pre-process delay the DAW should compensate for), not creative delay time — a delay or chorus plugin whose wet path includes a lookahead limiter, for example, should still declare the lookahead latency, but must not roll the delay/modulation time itself into that number.

## Worktrees

Git worktrees (e.g. created by Claude Code) are missing `rust/python-dist/`, `rustc-dist/`, and `ConjureDSPExtension/Resources/monaco/vs/` since they're gitignored. All three auto-symlink from the main worktree: `build-rust.sh` handles `python-dist/`, the "Copy Rust Compiler" build phase handles `rustc-dist/`, and the `SessionStart`/`PostToolUse` hooks in `.claude/settings.json` handle Monaco. So `xcodebuild build` and `xcodebuild test` work automatically in worktrees. For standalone `cargo test`, run the Xcode build first (to create the symlink) or manually: `ln -s /path/to/main/repo/rust/python-dist rust/python-dist`.

If you create a worktree manually (not via Claude Code), symlink Monaco yourself: `mkdir -p ConjureDSPExtension/Resources/monaco && ln -s /path/to/main/repo/ConjureDSPExtension/Resources/monaco/vs ConjureDSPExtension/Resources/monaco/vs`.

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
- **Python**: `libpython3.14t.dylib` in the AU extension (handled by "Copy Python Dylib" build phase), full Python distribution in ConjureDSPTerminal (handled by "Copy Python Runtime" build phase)
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
| AU Name | `ConjureDSP: ConjureDSP(Debug)` | `ConjureDSP: ConjureDSP` |

These are configured via per-configuration build settings (`CD_AU_SUBTYPE`, `CD_AU_NAME`, `PRODUCT_BUNDLE_IDENTIFIER`) in the pbxproj, referenced in `ConjureDSPExtension/Info.plist` via `$(VARIABLE)` substitution. Both the host app and extension use separate bundle IDs per configuration so PluginKit registers them independently — this prevents a Release build installed at `/Applications/` from shadowing the Debug extension during development.

## Export Preset as Standalone AUv3

Export ConjureDSP presets as standalone AUv3 plugins. All 5 phases complete. Full implementation plan in `docs/export-au-plan.md`, design Q&A in `docs/export-au-questions.md`. Key points:
- Both Python (.py) and Rust (.wasm) presets exportable
- Pre-built template AU (`ConjureDSPExportAUTemplate/`) — copy, patch plist, inject preset, ad-hoc sign
- App Group container for sandbox-safe writes from DAW-hosted AU extension
- Shared Python runtime at `~/Library/Application Support/ConjureDSP/PythonRuntime-3.14/`
- Licensed users only can export; exported AUs run freely
- Post-export validation: checks preset file integrity (WASM magic bytes, Python `def process`), runtime-config.json validity
- Rich parameter metadata flows through export: `ParamMetadata` → `runtime-config.json` → exported AU parameter tree

### Export Integration Tests

The test target (`ConjureDSPTests`) has its own copy of `ExportManager.swift` with a local `ParamMetadata` struct (since the test target cannot import the AU extension module). Integration tests in `ExportDSPIntegrationTests` use the Rust FFI directly — no AU instantiation needed:
1. Export a preset via `ExportManager` (with `skipSigning: true`)
2. Read the exported preset file (`.wasm` or `.py`) back from the bundle
3. Load into a fresh `DSPKernel` via `dsp_kernel_load_wasm()` or `dsp_kernel_load_script()`
4. Process a sine wave and verify output (passthrough match or expected attenuation)

## Backlog Management

At the start of every session, read `backlog.md` in the repo root. Always begin a session by reading backlog.md and briefly summarizing current status. At the end of every session (or when completing/starting features), update `backlog.md` to reflect:
- Newly completed features (move from "To Do" or "In Progress" to "Done" with the date)
- Any new feature requests or ideas that came up during the session
- Any items that moved to "In Progress"

Always keep `backlog.md` as the source of truth for project status.
