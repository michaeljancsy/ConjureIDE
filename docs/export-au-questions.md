# AUv3 Preset Export — Planning Questions & Answers

This document captures the design Q&A for the "Export Preset as Standalone AUv3" feature.

---

## Area 1: What Gets Exported

### Q1. Which languages should be exportable?

**Answer:** Both. Python presets export with .py source. Rust presets export as compiled .wasm binary only (no source).

### Q2. What about parameter definitions?

Should the export flow let the user name parameters, set ranges/units, choose how many to expose, or just ship with the same 8 generic params?

**Answer:** Ship with the same 8 generic params for v1. Parameter customization (naming, ranges, count) is a future enhancement.

### Q3. Should the exported AU have any UI?

Options: (a) No custom UI, (b) Minimal generic sliders, (c) Full BearBone editor, (d) Subset (sliders + spectrogram)

**Answer:** b - make it have sliders

### Q4. Should the exported AU include the source code?

**Answer:** Python exports include the .py source (inherently visible). Rust exports ship only the compiled .wasm binary (opaque, protects IP).

### Q5. Licensing for exported AUs?

Options: (a) Run freely, (b) Inherit parent license, (c) Own demo/license system

**Answer:** Licensed users only can export (the "compiler" is the paid product). Exported AUs run freely with no license check.

---

## Area 2: The Template AU App Bundle

### Q6. Should the template app be a separate Xcode target or a separate project?

**Answer:** separate. it should be it's own app bundle

### Q7. What should the template host app do when launched?

Options: (a) Blank window, (b) Simple test UI, (c) Auto-register and quit

**Answer:** Auto-register-and-quit. The app launches, macOS discovers the embedded .appex, and the app immediately terminates. Minimal friction.

### Q8. Template app naming?

**Answer:** "[Effect Name].app" containing "[Effect Name].appex". No BearBone branding in the exported app name.

### Q9. Bundle identifiers?

**Answer:** `com.BearBone_user.Export.<sanitized-name>` — tied to the developer identity for code signing consistency.

---

## Area 3: The Shared Python Runtime

### Q10. Shared runtime location and installation?

**Answer:** `~/Library/Application Support/BearBone/PythonRuntime-3.14/`. Auto-installed on first BearBone launch (not just on first export). Same content as `rust/python-dist/` but in the shared location.

### Q11. Runtime versioning?

**Answer:** Version the path (e.g., `PythonRuntime-3.14/`). Exported AUs pin to the version they were exported with. Document that updating BearBone may require re-exporting old presets.

### Q12. What if the user doesn't have BearBone installed?

Scenario: someone shares an exported AU with a friend.

**Answer:** The exported AU shows an error UI with a download button/link that auto-installs the Python runtime (downloads it directly, same as `setup-python.sh` does). No need to install full BearBone.

---

## Area 4: The Export Pipeline

### Q13. Where does export happen?

Options: (a) Host app, (b) AU extension, (c) Menu item in host app

**Answer:** From the AU extension itself (toolbar button). Uses App Group container for sandbox-safe writes from DAW-hosted extension. The extension writes to the App Group container, then the host app (or a helper) moves/signs the output.

### Q14. Export output location?

**Answer:** App Group container initially. Post-export, reveal in Finder or provide a way for the user to move it to /Applications or wherever they want.

### Q15. Code signing at export time?

**Answer:** Ad-hoc signing (`codesign -s -`) as default for local use. Provide instructions for notarization if users want to share.

### Q16. What actually happens during export?

Pipeline:
1. Copy pre-built template .app to App Group container
2. If Rust preset: embed compiled .wasm in .appex Resources
3. If Python preset: embed .py in .appex Resources
4. Patch Info.plist (bundle ID, AU subtype, display name, version)
5. Patch any hardcoded strings (app name, window title)
6. Ad-hoc sign the entire bundle
7. Notify user / reveal in Finder

No xcodebuild at export time — template is pre-built.

---

## Area 5: AU Identity & Coexistence

### Q17. Subtype generation?

**Answer:** Hash the preset name to 4 chars. Accept the small collision risk. If collision is detected (check against known exports in a local JSON registry), append a counter.

### Q18. Manufacturer code?

**Answer:** `BEAR` (same as BearBone). Identifies exported AUs as BearBone family.

### Q19. What if the user exports the same preset twice?

**Answer:** Detect the duplicate (by name) and overwrite the previous export. Same AU identity so DAW sees it as an update, not a duplicate.

---

## Area 6: Error Handling & User Experience

### Q20. Runtime missing UI?

**Answer:** SwiftUI view replacing the AU's normal UI, with clear instructions and a download button that auto-installs the Python runtime.

### Q21. Export progress?

**Answer:** Simple spinner/progress indicator in the toolbar area.

### Q22. Post-export?

**Answer:** Reveal the exported .app in Finder. Show brief instructions ("Launch the app once to register, then find it in your DAW").

---

## Area 7: Documentation & Implementation

### Q23. How should we document the plan?

**Answer:** Separate `docs/export-au-plan.md` with a summary reference in `CLAUDE.md`. Add to `backlog.md` with phases.

### Q24. Implementation phasing?

**Answer:** 5 phases:
- Phase 1: Template AU project (new Xcode target, minimal host app, WASM-only player AU)
- Phase 2: Export pipeline (copy template, inject preset, patch identity, sign)
- Phase 3: Export UI in AU extension (trigger export, progress, post-export flow)
- Phase 4: Python support (shared runtime, fallback chain, error UI)
- Phase 5: Polish (parameter naming, validation, instructions)

### Q25. Testing strategy?

**Answer:** Unit tests for the export pipeline (plist patching, signing, validation). Integration test that exports an AU and loads it via `AVAudioUnit.instantiate`. UI tests for the export button flow.
