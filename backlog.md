# Project Backlog

## In Progress
-

## To Do
- Save/load scripts from previous sessions (persistent script storage)
- Syntax highlighting in the script editor
- Mono and stereo track compatibility

## Done
- Worktree test support (2026-02-27): `build-rust.sh` auto-symlinks `rust/python-dist/` from main worktree when missing (gitignored dir). All 20 tests (15 unit + 5 UI) pass from a worktree.
- Resizable plugin window (2026-02-27): Extension (`AudioUnitViewController`) sets `preferredContentSize` (600x500), `preferredMinimumSize` (400x300), `preferredMaximumSize` (1400x800). Host app (`ContentView`) uses flexible frame modifiers, `sizeThatFits` on representable bridge, `.defaultSize(700, 650)` on WindowGroup. Resizes in Logic Pro (fixed aspect ratio — host limitation). Ableton does not support AUv3 resize. Added 2 Swift tests for resize properties (preferredContentSize and min<pref<max verification via proxy VC).
- Test suite expansion (2026-02-27): 37 Rust tests (+22 new: FFI layer, kernel edge cases, Python error recovery/hot-reload/bad scripts) + 13 Swift unit tests (+7 new: render resource lifecycle, render block passthrough/stereo/bypass) + 3 real UI tests (script editor, save button, default script). Fixed `cargo test` linking (added build.rs for python-dist lib path). Added accessibility identifiers to SwiftUI views.
- Automated test suite — basic foundation (2026-02-27): 15 Rust tests (kernel defaults, bypass, passthrough, stereo, Python script loading, gain processing) + 6 Swift tests (AU registration, instantiation, bus config, bypass, channel capabilities)
