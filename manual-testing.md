# Manual Testing Checklist

Incomplete test items from open PRs. Check off as you verify each item.

## PR #202 — [Fix truncated terminal welcome message](https://github.com/michaeljancsy/conjuredsp-application/pull/202)

- [ ] Launch ConjureDSP without Claude Code installed — verify the full welcome message renders in the terminal
- [ ] Launch with Claude Code installed — verify auto-launch still works

## PR #201 — [Fix stale App Group provisioning on app update](https://github.com/michaeljancsy/conjuredsp-application/pull/201)

- [ ] Manual: install previous version, then update to this build — verify rustc-dist is re-provisioned with correct entitlements

## PR #198 — [Clean up cargo cache after failed crate installs](https://github.com/michaeljancsy/conjuredsp-application/pull/198)

- [ ] Install an incompatible crate (e.g. one with native deps), verify error appears and cargo cache is cleaned
- [ ] Install a compatible crate, then attempt an incompatible one — verify cache is NOT cleaned (existing crate deps preserved)

## PR #164 — [Require NAM redistribution certification on preset export](https://github.com/michaeljancsy/conjuredsp-application/pull/164)

- [x] Manual: load `preset_nam.py`, click Export, verify certification section appears and Export button is disabled until a choice is made
- [x] Manual: load a non-NAM preset (e.g. `preset_lowpass.py`), click Export, verify certification section is hidden and Export works as before
- [x] Manual: load `preset_nam_rust.rs`, run it, click Export, verify certification section appears
- [x] Manual: cancel the popover after selecting an option, re-open it, verify the selection does not carry over

## PR #163 — [NAM tone browser: splice imports and instantiation following conventions](https://github.com/michaeljancsy/conjuredsp-application/pull/163)

- [x] Same in Rust mode — comment + `conjuredsp::nam!(...)` above `fn process`, above `#[no_mangle]` if present
- [x] Click **Use** on a freshly-downloaded tone — same behavior; URL persists across app restart
- [x] Click **Use** on a pre-existing downloaded tone (metadata.json without `toneUrl`) — only title comment appears, no crash

## PR #156 — [Build numpy/scipy against Accelerate instead of OpenBLAS](https://github.com/michaeljancsy/conjuredsp-application/pull/156)

- [x] Delete `rust/python-dist/` and re-run `cd rust && ./setup-python.sh`
- [x] `rust/python-dist/bin/python3 -c "import numpy; numpy.show_config()"` — confirm Accelerate/vecLib, not openblas
- [x] `rust/python-dist/bin/python3 -c "import numpy as np; a = np.random.randn(100,100); print(np.linalg.eigh(a)[0][:3])"` — functional check
- [x] Run unit tests to verify no regressions

## PR #154 — [Plan: Replace NAM condition mix loop with matmul_acc](https://github.com/michaeljancsy/conjuredsp-application/pull/154)

- [x] Plan only — no code changes to test

## PR #152 — [Add numpy/scipy Accelerate linkage plan](https://github.com/michaeljancsy/conjuredsp-application/pull/152)

- [x] Delete `rust/python-dist/` and re-run `rust/setup-python.sh`
- [x] Run `rust/python-dist/bin/python3 -c "import numpy; numpy.show_config()"` and confirm Accelerate/vecLib appears, not openblas

## PR #132 — [Consolidate App Group container URL resolution to reduce TCC prompts](https://github.com/michaeljancsy/conjuredsp-application/pull/132)

- [x] Launch ConjureDSP host app — count permission prompts (should be reduced from multiple to 0-1)
- [x] Load ConjureDSP as AU in Logic Pro — count permission prompts
- [x] Verify subscription status loads correctly
- [x] Verify MCP server starts and Claude Code terminal connects
- [x] Verify export functionality still works

## PR #129 — [Add Cmd+Shift+A keyboard shortcut for Save As](https://github.com/michaeljancsy/conjuredsp-application/pull/129)

- [x] Press Cmd+Shift+A → Save As popover opens with current preset name pre-filled
- [x] Save As still works via toolbar button
- [x] Cmd+S still saves directly for mutable modified presets

## PR #126 — [Fix exported Python AUs failing to load in DAWs](https://github.com/michaeljancsy/conjuredsp-application/pull/126)

- [x] Export a Python preset that uses `from conjuredsp import ...` — verify it loads and processes audio in Ableton
- [x] Export a Python preset with a deliberate error — verify the error banner appears with full message and copy button works
- [x] Export a Rust/WASM preset — verify it still loads correctly
- [ ] Run unit tests: `xcodebuild test -only-testing:ConjureDSPTests`

## PR #125 — [Use unique Python module names per AU instance](https://github.com/michaeljancsy/conjuredsp-application/pull/125)

- [ ] Standalone multi-instance isolation tests in `rust/multi_instance_test/` verify: independent output, module-level state isolation, concurrent thread safety, reload isolation, and module name collision fix
- [ ] Load ConjureDSP on two tracks in a DAW with different presets, verify both produce correct independent output

## PR #122 — [Add 100 community presets with Python + Rust implementations and parity tests](https://github.com/michaeljancsy/conjuredsp-application/pull/122)

- [ ] Run `xcodebuild test -only-testing:ConjureDSPTests/CommunityPresetParityTests` to verify Python/Rust parity
- [ ] Spot-check a few presets in the plugin (load .py, listen, load .rs, compare)
- [ ] Verify parity test auto-discovers all 100 preset pairs

## PR #115 — [Add Python package management](https://github.com/michaeljancsy/conjuredsp-application/pull/115)

- [ ] Run `scripts/setup-uv.sh` and verify `uv-dist/uv` exists
- [ ] `cargo test -- --test-threads=1` — all 233 Rust tests pass
- [ ] `xcodebuild -scheme ConjureDSPTerminal build` succeeds with uv in app bundle
- [ ] Xcode build compiles all Swift targets (ConjureDSP, ConjureDSPExtension, ConjureDSPTerminal)
- [ ] Packages button (shippingbox icon) appears in AU toolbar
- [ ] Clicking opens popover with PyPI search, installed list, install input
- [ ] End-to-end: install a pure-Python package, write a script importing it, verify it works
- [ ] Uninstall removes the package and its dist-info directory

## PR #90 — [Add ETag caching, retry/backoff, and tests to GitHub integration](https://github.com/michaeljancsy/conjuredsp-application/pull/90)

- [ ] Open community browser, verify presets load; reload and check console for ETag cache hits
- [ ] Verify no regressions in personal repo sync flow

## PR #88 — [Add Monaco inline error markers and custom color themes](https://github.com/michaeljancsy/conjuredsp-application/pull/88)

- [x] Write a Python script with a syntax error — verify red squiggly appears on the correct line
- [x] Write a Rust script with a type error — verify marker on correct line
- [x] Fix the error and re-run — verify markers clear
- [x] Switch between all 9 theme options in Settings — verify colors apply
- [x] Set "Auto (System)" and toggle macOS dark/light mode — verify theme follows
- [x] Restart the plugin — verify theme preference persists

## PR #87 — [Add real-time process function profiler](https://github.com/michaeljancsy/conjuredsp-application/pull/87)

- [x] Manual: load a DSP script, play audio, verify status bar shows live updating timing
- [x] Manual: load a heavy script, verify peak/avg reflect higher processing time
- [x] Manual: bypass, verify profiler stops updating

## PR #86 — [Add conjuredsp Rust library and migrate factory presets](https://github.com/michaeljancsy/conjuredsp-application/pull/86)

- [x] Manual: open app, load factory Rust presets, verify audio output
- [x] Manual: create new Rust script from template, verify it compiles and runs

## PR #81 — [Add Sparkle auto-update framework](https://github.com/michaeljancsy/conjuredsp-application/pull/81)

- [ ] Launch app and verify "Check for Updates..." appears in the app menu
- [ ] After configuring feed URL + EdDSA key, test full update flow per the integration plan

## PR #78 — [Replace license keys with Paddle Billing subscriptions](https://github.com/michaeljancsy/conjuredsp-application/pull/78)

- [ ] Manual: deploy server to Cloudflare staging, test Paddle sandbox checkout -> activation -> token refresh -> grace period -> demo fallback
