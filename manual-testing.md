# Manual Testing Checklist

Incomplete test items from open PRs. Check off as you verify each item.

## PR #241 — [Lower deployment target to macOS 15 (Sequoia)](https://github.com/michaeljancsy/conjuredsp-application/pull/241)

- [ ] Smoke-test a Debug build on an actual macOS 15 (Sequoia) machine — host app launches, AU registers in a DAW, a Python and a Rust preset both process audio
- [ ] Regenerate `ConjureDSPExportAUTemplate.xcodeproj` via XcodeGen to pick up the `project.yml` change
- [ ] Sanity-check that the export flow still produces a working standalone AU

## PR #238 — [Modular language installer (Phases 1–3) — do NOT merge until release-ready](https://github.com/michaeljancsy/conjuredsp-application/pull/238)

- [ ] Publish `catalog.json` + `rustc-1.93.1-aarch64.tar.gz` + `python-*.tar.gz` to R2 (without this, the Languages panel 404s)
- [ ] Strip Python from Release bundle (mirror Phase 3e: `CD_BUNDLE_PYTHON` flag + gate the Copy Python phases)
- [ ] Size-guard CI assertion (e.g. fail if signed .app > 400 MB)
- [ ] DAW-hosted verification of a signed Release: factory Rust + Python presets play from sidecar/stripped, rustc module install works end-to-end, user-edit triggers install CTA
- [ ] Release notes / first-launch migration sheet ("on-demand languages, pick what you need") with sensible defaults
- [ ] Release pipeline (`scripts/release.sh`) updated to publish modules alongside the app

## PR #237 — [HTML/JS custom UIs for preset authors (Phases A–D)](https://github.com/michaeljancsy/conjuredsp-application/pull/237)

- [ ] Manual: toggle between custom UI and stock sliders for a bundle → choice survives plugin reload
- [ ] Manual: pick `manifest.json` or `ui/index.html` in the editor picker → save → hot-reload lands in the custom UI
- [ ] Manual: MCP `write_bundle_file` with `path=ui/index.html` from Claude Code terminal → same hot-reload path
- [ ] Manual: export a bundle preset with a custom UI → open exported AU in a DAW → VU meters animate
- [ ] Manual: connect personal GitHub repo → save a bundle with a PNG in `ui/assets/` → round-trips; edit same bundle on two machines, connect one without pulling → bundle-conflict row appears with keep-local/keep-remote

## PR #156 — [Build numpy/scipy against Accelerate instead of OpenBLAS](https://github.com/michaeljancsy/conjuredsp-application/pull/156)

- [ ] Delete `rust/python-dist/` and re-run `cd rust && ./setup-python.sh`
- [ ] `rust/python-dist/bin/python3 -c "import numpy; numpy.show_config()"` — confirm Accelerate/vecLib, not openblas
- [ ] `rust/python-dist/bin/python3 -c "import numpy as np; a = np.random.randn(100,100); print(np.linalg.eigh(a)[0][:3])"` — functional check
- [ ] Run unit tests to verify no regressions

## PR #152 — [Add numpy/scipy Accelerate linkage plan](https://github.com/michaeljancsy/conjuredsp-application/pull/152)

- [ ] Delete `rust/python-dist/` and re-run `rust/setup-python.sh`
- [ ] Run `rust/python-dist/bin/python3 -c "import numpy; numpy.show_config()"` and confirm Accelerate/vecLib appears, not openblas

## PR #122 — [Add 100 community presets with Python + Rust implementations and parity tests](https://github.com/michaeljancsy/conjuredsp-application/pull/122)

- [ ] Run `xcodebuild test -only-testing:ConjureDSPTests/CommunityPresetParityTests` to verify Python/Rust parity
- [ ] Spot-check a few presets in the plugin (load .py, listen, load .rs, compare)
- [ ] Verify parity test auto-discovers all 100 preset pairs
