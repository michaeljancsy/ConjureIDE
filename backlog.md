# Project Backlog

## In Progress
-

## To Do
- Save/load scripts from previous sessions (persistent script storage)
- Support other scripting languages beyond Python
- Visualization and diagnostics in the Mac host app (not just the AU extension)
## Done
- Syntax highlighting in the script editor (2026-02-27): Replaced SwiftUI `TextEditor` with `NSTextView` wrapped in `NSViewRepresentable`. Regex-based `PythonSyntaxHighlighter` colors keywords, builtins, strings (single/double/triple-quoted), comments, numbers, decorators, and def/class names. Xcode-inspired dark/light themes auto-switch with system appearance. No third-party dependencies. All 15 Swift unit + 5 UI tests pass.
- Process function benchmark on save (2026-02-27): Added `benchmark_process()` to Rust kernel — runs 1 warm-up + 5 timed iterations with 440 Hz sine wave, returns max time. Exposed via `dsp_kernel_benchmark_process()` FFI. Swift `reloadScript()` calls benchmark after successful load and returns process time + budget (frame_count/sample_rate). UI shows color-coded timing: green (<50% budget), orange (50–100%), red (>100%). 40 Rust tests (+3 new benchmark tests), 15 Swift unit tests, 5 UI tests all pass.
- Mono and stereo track compatibility (2026-02-27): Confirmed plugin already passes `auval` validation for both mono (1→1) and stereo (2→2). Root cause of Logic Pro not showing plugin on mono tracks: stale AU cache. Fix: bumped AU component version (67072→67073) to force Logic rescan, reduced `maximumChannelCount` from 8→2 to match declared `channelCapabilities` (eliminates auval warnings about unsupported channel counts 4-8). After merge, user must clear AU cache (`rm ~/Library/Caches/AudioUnitCache/com.apple.audiounits.cache`) and relaunch Logic.
- Worktree test support (2026-02-27): `build-rust.sh` auto-symlinks `rust/python-dist/` from main worktree when missing (gitignored dir). All 20 tests (15 unit + 5 UI) pass from a worktree.
- Resizable plugin window (2026-02-27): Extension (`AudioUnitViewController`) sets `preferredContentSize` (600x500), `preferredMinimumSize` (400x300), `preferredMaximumSize` (1400x800). Host app (`ContentView`) uses flexible frame modifiers, `sizeThatFits` on representable bridge, `.defaultSize(700, 650)` on WindowGroup. Resizes in Logic Pro (fixed aspect ratio — host limitation). Ableton does not support AUv3 resize. Added 2 Swift tests for resize properties (preferredContentSize and min<pref<max verification via proxy VC).
- Test suite expansion (2026-02-27): 37 Rust tests (+22 new: FFI layer, kernel edge cases, Python error recovery/hot-reload/bad scripts) + 13 Swift unit tests (+7 new: render resource lifecycle, render block passthrough/stereo/bypass) + 3 real UI tests (script editor, save button, default script). Fixed `cargo test` linking (added build.rs for python-dist lib path). Added accessibility identifiers to SwiftUI views.
- Automated test suite — basic foundation (2026-02-27): 15 Rust tests (kernel defaults, bypass, passthrough, stereo, Python script loading, gain processing) + 6 Swift tests (AU registration, instantiation, bus config, bypass, channel capabilities)
