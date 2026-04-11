# Manual Testing Checklist

Incomplete test items from open PRs. Check off as you verify each item.

## PR #220 — [Rename AU manufacturer from "Michael Jancsy" to "ConjureDSP"](https://github.com/michaeljancsy/conjuredsp-application/pull/220)

- [ ] Debug build: `xcodebuild -project ConjureDSP.xcodeproj -scheme ConjureDSP build`
- [ ] Verify embedded Info.plist has the new name: `/usr/libexec/PlistBuddy -c "Print :NSExtension:NSExtensionAttributes:AudioComponents:0:name" <DerivedData>/Debug/ConjureDSP.app/Contents/PlugIns/ConjureDSPExtension.appex/Contents/Info.plist`
- [ ] `pluginkit -mv -p com.apple.AudioUnit-UI | grep ConjureDSP` shows the extension registered and elected
- [ ] In Logic and Ableton, rescan Audio Units and confirm the plugin now groups under "ConjureDSP"
- [ ] Existing Live/Logic project with the plugin still loads the instance correctly

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
