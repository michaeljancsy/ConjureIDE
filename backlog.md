# Project Backlog

## In Progress
-

## To Do
- Resizable plugin window
- Save/load scripts from previous sessions (persistent script storage)
- Syntax highlighting in the script editor
- Mono and stereo track compatibility

## Done
- Test suite expansion (2026-02-27): 37 Rust tests (+22 new: FFI layer, kernel edge cases, Python error recovery/hot-reload/bad scripts) + 13 Swift unit tests (+7 new: render resource lifecycle, render block passthrough/stereo/bypass) + 3 real UI tests (script editor, save button, default script). Fixed `cargo test` linking (added build.rs for python-dist lib path). Added accessibility identifiers to SwiftUI views.
- Automated test suite — basic foundation (2026-02-27): 15 Rust tests (kernel defaults, bypass, passthrough, stereo, Python script loading, gain processing) + 6 Swift tests (AU registration, instantiation, bus config, bypass, channel capabilities)
