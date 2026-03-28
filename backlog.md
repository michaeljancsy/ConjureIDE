# Project Backlog

## In Progress

## To Do

### v1 Release
- Run `scripts/release.sh` end-to-end, store notarization creds in Keychain, verify DMG on clean machine. Full plan at `docs/distribution-plan.md`.
- Deploy Paddle subscription server (Cloudflare Worker, Ed25519 keypair, Paddle webhooks)
- Landing page (static site with Buy + Download)
- In-app "Buy" link for unlicensed users


### DSP & Audio
- Process function profiler: real-time stats on `process()` duration (median, peak, % budget). Two `mach_absolute_time()` calls around `dsp_kernel_process` (~50 ns overhead), atomics to main thread. No locks or allocations on audio thread.
- Memory leak detection: periodic resident memory sampling via `task_info` from main thread. Flag monotonic growth as likely script leak. Zero audio-thread overhead.
- Preset comparison tests: tighten tolerance (investigate native Rust compilation instead of WASM to eliminate libm differences)

### UI & Editor
- Investigate ACP (Audio Code Protocol) and more full-fledged IDE features for the editor
- AI-powered autocomplete (context-aware LLM suggestions)
- Claude Code terminal polish: auto-launch companion app, terminal reconnect UX, DAW testing
- Audio visualization polish: persist spectrogram preferences in UserDefaults, add spectrogram to host app
- Full-screen text editor mode
- Make scrolling smoother

### Post-Launch
- Python package management: in-script `REQUIREMENTS` metadata, per-preset isolated environments, companion app as installer, vendored exports, configurable Python path for exported AUs. Revised design at `docs/per-preset-package-requirements.md`, supersedes Phase 2B/3 of `docs/python-package-management.md`. Phase 2A infrastructure (sys.path wiring, Rust FFI) still needed as foundation.

### Other
- AI Python quality: verify AI-generated scripts use numpy vectorized ops (not per-sample iteration)
- Add link to website for licensing

## Done

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
