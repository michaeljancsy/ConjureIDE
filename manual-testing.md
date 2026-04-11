# Manual Testing Checklist

Incomplete test items from open PRs. Check off as you verify each item.

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
