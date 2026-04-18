# Project Backlog

## In Progress

- Python package management: global `user-packages/` directory, package manager UI in AU extension, companion app installer via `uv`. Design at `docs/per-preset-package-requirements.md`. Remaining: vendored exports.
- Rust crate package management: crates.io search + install UI, companion app compiles crates to wasm32-wasip1 rlibs via bundled cargo, RustCompiler links user crates via `--extern` flags, WasmCache invalidates on dependency changes. Remaining: manual testing end-to-end with real crates.
- HTML/JS custom preset UIs (amorph-style): directory-bundle preset format with optional `ui/index.html` that replaces the default parameter sliders. Plan at `~/.claude/plans/adaptive-bouncing-stallman.md`. Phase A landed: `PresetManifest` + `PresetBundle`, all save paths (Save button, MCP `save_preset`, import-URL) now produce bundles via `saveUserBundle` / `saveRepoBundle`; manifest always advertises `ui/index.html` so authors activate a custom UI by creating that file in any editor. Legacy single-file presets still load for backward compat. No conversion feature (would become dead code). 47 tests pass. Remaining: PersonalRepoSync bundle sync, `CustomUIWebView` + `window.ConjureDSP` bridge, audio-frame publisher (RMS/FFT/waveform), hot reload + preset-browser Reveal/Reload menu, Export AU support.

## To Do

### v1 Release
- NAM exports work
- export pipeline flags/gates exporting NAM tones without explicit authorization from the creator of the tone
- Terminal auto-quit: ConjureDSPTerminal stays running as an invisible orphan (LSUIElement) after DAW/host closes. Should auto-quit after inactivity (no active sessions in mcp-instances/).
- Landing page (static site with Buy + Download)
- Single-source download URL config: one config file in the repo defining the canonical download link, referenced everywhere (landing page, in-app links, etc.) so it only needs updating in one place
- Migrate existing `RepoPresets/` directories into the new `Presets/.git` layout. The git-backed presets refactor (plan at `~/.claude/plans/bright-conjuring-stonebraker.md`) assumes a fresh install. Before shipping, either (a) on first run, if `Presets/` has no `.git` and `RepoPresets/` is non-empty, move files across and resolve name collisions with `" 2"`, `" 3"`; or (b) show a one-time migration dialog with a local-first / remote-first choice. MUST be done before tagging a release that includes the refactor.

### Post-Launch
- Server-side `/deactivate` endpoint: today's "Deactivate License" button only clears the local token — the server's `activations` row is left behind until the subscription expires. Add a `POST /deactivate` route to `server/src/index.ts` (and a matching `SubscriptionAPI.deactivate(token:machineID:)` client call) that deletes the `(subscription_id, machine_id)` row so the activation slot is immediately reusable on another machine. `SubscriptionManager.deactivateLicense()` should call it best-effort (still clear the local token even if the network call fails, so users without internet can still deactivate).
- Git-backed presets follow-ups: (1) switch PAT delivery from a short-lived 0600 token file in the App Group to a `GIT_ASKPASS` stdin pipe so the PAT never touches disk; (2) add `pull` command to `GitWorker` + conflict-resolution sheet UI (keep local / keep remote / merge) — v1 ships push-only; (3) add `log` command + a simple commit-history pane under the preset toolbar; (4) add SSH remote support (v1 is HTTPS + PAT only); (5) revisit bundling `git` inside ConjureDSPTerminal (~20 MB + GPL disclosures) if telemetry shows Command Line Tools install-prompt friction; (6) coalesce queued commits on terminal startup (if user did 20 saves while terminal was down, collapse overlapping `commit` requests into one commit with a synthesized message); (7) document (or drop a `.nosync` marker) for users who unusually sync `~/Library/Application Support` via iCloud/Dropbox — `.git` in a synced directory would corrupt the repo.
- Python package management follow-up: vendored exports (import analysis + export UI), community browser dependency badges
- Support pyo3/numpy-dependent Rust crates in WASM: crates like `spectrograms` that depend on pyo3+numpy can't cross-compile to wasm32-wasip1 because pyo3's build script requires a Python interpreter. We already bundle Python 3.14 and numpy — investigate setting `PYO3_CROSS_PYTHON_VERSION` and `PYO3_CROSS_LIB_DIR` in the cargo environment so pyo3-based crates can compile. Would unlock the whole pyo3/numpy Rust ecosystem for user scripts.
- Native Rust compilation mode ("use at your own risk"): opt-in alternative to WASM that compiles user scripts + crates natively to aarch64-apple-darwin as a dylib, loaded at runtime. Unlocks the full Rust crate ecosystem (pyo3, openssl, C bindings, etc.) but loses WASM fuel metering (no infinite loop protection). Could be a per-preset toggle or a global setting. Requires a separate native compilation path in RustCompiler, native crate builds in CrateInstaller, and a native backend alongside wasm_backend in the kernel.

### Bugs
- v1.0.9 still has loud noise when switching presets — the 5ms declick fade envelope (39194e7) is not fully eliminating the glitch in the shipped build; needs further investigation.
- Cmd+Shift+A triggers Ableton's project save as dialog instead of the extension's save as dialog
- `ConjureDSPTests.rustFactoryPresetsHaveRustContent` hardcodes `rustPresets.count == 27` at `ConjureDSPTests/ConjureDSPTests.swift:441`; after PRs #212/#217 the actual count is 52. Bump the expectation (and consider switching to a lower-bound `>=` so future preset additions don't break the test).
- Toolbar tooltips don't appear on hover. `ToolbarTooltip` ViewModifier in `ConjureDSPExtension/UI/PresetToolbar.swift` shows a floating label 600ms after `.onHover` fires true, but the hover state either never fires or the overlay doesn't render through the AU ViewBridge. Affects every toolbar button — users have no way to discover keyboard shortcuts (⌘R Run, ⌘S Save, ⇧⌘E Files, etc.) from the UI. Investigate whether `.onHover` works in the AU host; if not, switch to native `.help(...)` + a short-text label in the button, or expose the shortcut in the button's accessibilityLabel.
- TerminalServer writes to `mcp-instances/*.json` in the Group Container can still be blocked by `com.apple.quarantine` xattr on the `mcp-instances/` directory after a signing-identity change. `AppGroupContainer.url` strips quarantine 2 levels deep on first access (commit 4e42f83), so `PresetManager` paths are covered, but the terminal worker uses its own file writing path in `ConjureDSPTerminal/` that doesn't go through the same helper. Either (a) have the companion app call `xattr -d com.apple.quarantine` on its writes, or (b) centralize the Group Container setup on first launch so every subdir is de-quarantined before any process writes. Symptom: every ~5s "Failed to write instance file: You don't have permission…" spam in the log, harmless but noisy and occasionally produces stale MCP port state.

### UX
- Make the ConjureDSPTerminal (companion app) icon visible in the Dock so users can see when it's running
- Stereo / width visualization

### Optimization
- Preset optimization: audit factory presets for render-loop inefficiencies (allocations, per-sample Python, redundant math).
- Rust optimization: audit Rust/WASM presets and conjuredsp-rs for autovectorization blockers, bounds checks, branchy inner loops; verify LLVM is vectorizing the hot paths.

### Other
- Export AU instantiation tests: add integration tests that instantiate exported AUs via `AVAudioUnitComponentManager` (the full DAW loading path) rather than just testing the Rust FFI directly. Would catch issues like Debug template stubs, `findPythonHome` sandbox failures, PluginKit registration, and parameter tree setup — bugs that the current `ExportDSPIntegrationTests` miss because they bypass the Swift AU class.
- Self-contained Python exports: option to bundle a Python runtime directory inside the exported AU (in Resources/python-dist), making Python exports shareable across machines without requiring ConjureDSP to be installed. Tradeoff is ~100MB per exported AU.
- AI Python quality: verify AI-generated scripts use numpy vectorized ops (not per-sample iteration) — prompt improvements made 2026-04-02 (tick_n, conventions section, array indexing)

## Done

- HeroScrollColumns presets: 8 sophisticated Python + 8 Rust/WASM showpiece presets matching the website hero prompts — Haunted Cathedral, Dying Star, Broken Fax Lullaby, Sun-Baked Cassette, Alien Radio, Underwater Spy, Glass Smash, Ghost Choir. Each pair uses techniques like dual-tap pitch shifting, modal resonator banks, multi-carrier ring modulation, Schroeder reverb networks, frequency-dependent saturation, and mid/side widening. All 16 files pass `PresetComparisonTests` parity (1e-4 tolerance, A440 + white noise). Plan at `~/.claude/plans/majestic-doodling-liskov.md`. (2026-04-10)
- Beta build mode: `--beta` flag on `scripts/build.sh` injects `BETA_BUILD` Swift compilation condition. Plugin runs fully licensed for 7 days from the build date, shows a cyan "BETA" toolbar badge instead of amber "DEMO", disables the 60s demo timer, and auto-reverts to Demo (hourly re-check, no restart needed) once the window elapses. Pure Swift/Info.plist layer — no Rust/FFI/server changes. Used while Paddle subscription infra is offline. (2026-04-10)
- v1.0.4 release build: bumped version, fixed $SRCROOT→$PROJECT_DIR bug in build-release.sh (rustc entitlements path), built DMG, uploaded to R2 with appcast (2026-04-08)
- Multi-instance terminal support: each AU instance gets its own dedicated Claude Code PTY + WebSocket pair. Discovery uses mcp-instances/{uuid}.json directory instead of single port file. Terminal app manages multiple concurrent sessions, with per-instance health checks and stale PID cleanup. (2026-04-08)
- Embed terminal + fix macOS 26 TCC loop: embedded ConjureDSPTerminal in host app bundle (single DMG), deduplicated python-dist/rustc-dist, replaced manual Group Containers path with `containerURL(forSecurityApplicationGroupIdentifier:)` to fix endless `kTCCServiceSystemPolicyAppData` prompts, replaced URL scheme launch with `openApplication(at:)` to fix `kTCCServiceAppleEvents`, switched R2 uploads from wrangler to rclone (2026-04-08)
- Release pipeline end-to-end: fixed Xcode 17 archive/export issues (ONLY_ACTIVE_ARCH, manual signing, -exportArchive bypass), added Developer ID signing for all bundled binaries (Sparkle, python-dist, rustc-dist), bundle size reduction (stripped tests/cache/pip/sanitizers/cargo: 917MB→761MB, DMG 273MB), DMG sizing fix, Sparkle appcast generation, R2 upload. Notarization creds stored in Keychain. (2026-04-07)
- Host-side NAM inference for Rust/WASM presets: fixed two WaveNet buffer bugs (ping-pong addressing, cross-array head accumulation order), moved NAM inference from WASM sandbox to native host via `__conjuredsp_nam_process` import, added native Accelerate to accel module, fixed debug-mode optimization (15x speedup), zero-copy host import, WasmCache invalidation on rlib change (2026-04-03)
- AI prompt helper quality pass: tested 8 iterations across tremolo/compressor/chorus/flanger/filter-sweep/reverb/distortion, fixed conventions (imports, tick_n, 1.0 init, inputs indexing, lazy SR init), LFO tick() docs (frames-outer code examples), f64 cast requirement for Rust BiquadCoeffs (2026-04-02)
- tone3000 NAM support: Python `conjuredsp.nam.load_model()`, Rust `nam!()` macro, tone browser UI with OAuth, download/store .nam files, export embedding (2026-03-31)
- Terminal app icon from daemon-icon.png (2026-03-28)
- Smoother scrolling in editor (2026-03-28)
- Full-screen text editor mode (2026-03-28)
- Audio visualization polish: persist spectrogram preferences, host app spectrogram (2026-03-28)

- Comprehensive Monaco autocomplete for conjuredsp: Python/Rust dot-completions (Biquad, DelayLine, LFO, BiquadCoeffs::, Waveform::, ctx.), signature help on `(`, hover docs, function-level completions for DSP utils/param builders, latency!() macro, ParamSpec chain methods (2026-03-28)
- In-app "Buy" link for unlicensed users — subscribe buttons in SubscriptionSettingsView and demo-expired overlay linking to conjuredsp.com/subscribe (2026-03-28)
- Deploy Paddle subscription server — Cloudflare Worker at api.conjuredsp.com with activate/verify/webhook endpoints, D1 SQLite, Ed25519 token signing (2026-03-27)
- Website licensing link — buy/account URLs in subscription UI (2026-03-28)
- Process function profiler — ProcessProfiler.swift polling kernel FFI timing, status bar display of current/avg/peak ms and budget % (2026-03-28)
- Memory leak detection — MemoryMonitor.swift with sliding-window monotonic growth detection, WASM memory tracking, ok/warning/critical states (2026-03-28)
- Preset comparison tests — tolerances tightened to 1e-4, native Rust compilation via bundled rustc for wasm32-wasip1 (2026-03-28)
- Latency reporting for DAW compensation — scripts declare `LATENCY` (Python) or `latency!()` (Rust), AU reports via `AUAudioUnit.latency`, export pipeline includes in runtime-config.json, MCP tools report latency, Claude Code context guide documents the feature, lookahead limiter factory presets (Python + Rust) with parity tests (2026-03-27)
- Export AUv3 Phase 5: integration tests (export → FFI kernel → process audio for both Rust and Python), post-export validation (WASM magic bytes, Python process fn, JSON config), param metadata round-trip tests, edge case tests, documentation (2026-03-27)
- Claude Code terminal integration — MCP server in extension, companion app for PTY, xterm.js terminal UI, contentEditable keyboard input for ViewBridge (2026-03-27)
- GitHub integration — ETag HTTP caching, retry/backoff, unit tests (2026-03-26)
- Fix flaky `extensionPlistContainsBuildID` test — use Info.plist preprocessing instead of post-hoc stamping (2026-03-26)
- conjuredsp Rust library: rlib for wasm32-wasip1 with setup!/params! macros, DSP building blocks (Biquad, DelayLine, Lfo), and utility functions. All 25 factory Rust presets migrated. Parity tests pass. (2026-03-26)
- Monaco inline error markers (Python/Rust line parsing → squiggly underlines) + 6 custom color themes with settings picker (2026-03-26)
- Paddle subscription system — backend server, Rust token verification, Swift SubscriptionManager, UI, tests, cleanup of old license system (2026-03-25)
- BPM sync: host transport (tempo, beat, time sig, playing) piped through entire pipeline to Python/WASM scripts + tempo-synced delay preset (2026-03-25)
- Monaco numpy/scipy/signal autocomplete in editor-bridge.js (2026-03-25)
- Add Stereo Width Optimized preset alongside original (2026-03-25)
- Replace app icons with new designs + full-res source icons (2026-03-25)
- Use `np.multiply(out=)` in Python presets to avoid render-loop allocations (2026-03-25)
- Fix broken test symlinks from BearBone → ConjureDSP rename (2026-03-25)
- Monaco editor resilience: retry init on JS failure, handle WebContent process termination (2026-03-24)
- Fix 3 UI tests: ViewBridge-compatible element query for WKWebView (2026-03-24)
- Import URL improvements: auto-upgrade http→https, HTML detection, gist name derivation (2026-03-24)
- Rename BearBone to ConjureDSP across project (2026-03-24)
- Bundle scipy in Python runtime (2026-03-23)
- Rich parameters for WASM/Rust presets — all 22 factory presets (2026-03-23)
- Log curve mapping + export template rich parameters (2026-03-23)
- Rich parameter system with named access — PARAMS dict, real ranges, units (2026-03-23)
- GitHub integration — Phases 3–4: settings + personal repo sync (2026-03-23)
- GitHub integration — Phase 1: community browsing + import from URL (2026-03-23)
- All 18 remaining factory presets parametric (2026-03-22)
- Script-declared parameter names — Python PARAM_NAMES + WASM JSON export (2026-03-22)
- UI/UX polish pass — SF Symbol toolbar, keyboard shortcuts, resizable chat, status bar (2026-03-22)
- AI chat sidebar with tool use — 9 tools, agentic loop, streaming (2026-03-21)
- Release pipeline — archive, notarize, DMG (2026-03-21)
- Strip markdown code fences from AI-generated scripts (2026-03-21)
- Improve AU build reliability (2026-03-21)
- Phase 4: Python export support for standalone AUv3 (2026-03-21)
- Debug/Release AU identity separation + cache-busting (2026-03-19)
- Fix exported AU registration and worktree export support (2026-03-08)
- Fix TCC prompt — App Group entitlement (2026-03-07)
- Production Ed25519 keypair and license test automation (2026-03-07)
- Export UI + Host App Handler — Phase 3 (2026-03-05)
- Export Pipeline — Phase 2: ExportManager, ExportRegistry, SubtypeGenerator (2026-03-05)
- Export AU Template — Phase 1: minimal AUv3 template with WASM (2026-03-05)
- Demo expired overlay with restart button (2026-03-05)
- Ed25519 license system with demo mode (2026-03-05)
- Normalized difference spectrogram (2026-03-04)
- Preset comparison tests — Python vs Rust parity (2026-03-04)
- 18 new factory presets in Python + Rust (2026-03-04)
- Before/after/difference spectrogram visualization (2026-03-04)
- Parameter UI — 8 sliders with AUParameterTree ↔ SwiftUI bridge (2026-03-04)
- DAW parameter pipeline — 8 AUParameters, atomic Rust storage, Python/WASM delivery (2026-03-03)
- Fix backend swap crash — Mutex around backend field (2026-03-03)
- Safety limiter — hard clip at ±1.0 after processing (2026-03-03)
- Bundle Rust compiler for sandbox-safe WASM compilation (2026-03-03)
- Multi-language WASM DSP — Phases 1–5 (2026-03-02)
- Project rename: TestPlugin → ConjureDSP (2026-03-02)
- Script warm-start + real-time safety prompts (2026-03-02)
- AI streaming bug fix — SSE parser rewrite (2026-03-02)
- AI-assisted script generation — generate from prompt + fix with AI (2026-03-01)
- Preset browser + management (2026-03-01)
- Build ID in AU extension UI (2026-03-01)
- Fix host app AU loading — `.loadInProcess` (2026-03-01)
- Fix preset bugs — script editor sync + AU version bump (2026-02-28)
- Worktree AU identity patching (2026-02-28)
- Persistent script storage via fullState + 3 factory presets (2026-02-28)
- Syntax highlighting — regex-based PythonSyntaxHighlighter (2026-02-27)
- Process function benchmark on save (2026-02-27)
- Mono/stereo track compatibility (2026-02-27)
- Worktree test support — auto-symlink python-dist (2026-02-27)
- Resizable plugin window (2026-02-27)
- Test suite expansion — 37 Rust + 13 Swift + 3 UI tests (2026-02-27)
- Automated test suite foundation (2026-02-27)
