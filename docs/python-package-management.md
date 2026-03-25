# Python Package Management — Design & Implementation Plan

## Context

Users can currently only import numpy, scipy, and the Python stdlib in their DSP scripts. This feature lets users install additional Python packages from **PyPI**, **GitHub repos**, or **local paths** through the ConjureDSP host app. The AU extension is sandboxed in DAWs and cannot run subprocesses, so all package management happens in the unsandboxed host app. Packages are installed into a shared directory that the Rust/pyo3 layer adds to `sys.path`.

Phase 1 (bundle scipy) is already done. This plan covers Phases 2 and 3.

## Key Constraints

| Constraint | Impact |
|---|---|
| AU extension is **sandboxed** in DAWs | Cannot run uv/pip, limited filesystem access |
| Host app is **unsandboxed** | Can run uv, access filesystem freely |
| Bundled Python is **code-signed** | Cannot modify `python-dist/` inside the app bundle |
| **Free-threaded Python 3.14t** (no GIL) | Many packages don't have compatible wheels yet |
| `allow-unsigned-executable-memory` entitlement exists | Unsigned `.so` files can load (needed for wasmtime JIT) |
| App Group already exists | Extension ↔ host app communication channel available |
| Shared runtime at `~/Library/Application Support/ConjureDSP/PythonRuntime-3.14/` | Already used by exported AUs |
| `PYTHONHOME` controls stdlib + site-packages discovery | No `sys.path` manipulation exists today |

## Free-Threaded Python 3.14t Package Compatibility

| Package | Status | Notes |
|---|---|---|
| numpy | Works | Already bundled |
| scipy | Works | Already bundled, free-threaded wheels available since 1.14+ |
| Cython | Works | Since 3.1+ |
| librosa | Blocked | Depends on numba (no free-threaded support) |
| soundfile | Uncertain | cffi free-threaded support incomplete |
| torch/tensorflow | Blocked | No free-threaded support |
| Pure Python packages | Generally work | No C extensions to worry about |

**Practical reality:** For real-time DSP callbacks, numpy + scipy cover ~95% of needs. Most "audio" Python packages (librosa, madmom, essentia) are offline analysis tools too slow for real-time use anyway.

## Architecture

```
Host App (unsandboxed)                  AU Extension (sandboxed in DAWs)
┌───────────────────────────┐           ┌──────────────────────────────────┐
│ PackageManagerView        │           │ PythonBackend::load()            │
│   Install from PyPI/      │           │   → sys.path.insert(0,          │
│     GitHub/local          │           │       user-packages dir)         │
│   Uninstall               │           │                                  │
│ PackageInstaller          │           │ On ImportError:                  │
│   runs bundled `uv`       │           │   "Open ConjureDSP app to install"│
│   code-signs .so files    │           └──────────────────────────────────┘
└───────────────────────────┘
          │
          ▼
~/Library/Application Support/ConjureDSP/PythonRuntime-3.14/
  lib/python3.14t/site-packages/   ← bundled numpy/scipy (read-only)
  user-packages/                   ← NEW: user-installed packages
```

**Why separate `user-packages/` directory:** `SharedPythonRuntimeInstaller` replaces `lib/python3.14t/` wholesale on updates. A separate dir survives runtime reinstalls and cleanly separates user packages from bundled ones.

**Why uv over pip:**
- Same maintainers as python-build-standalone (Astral) — first-class free-threaded 3.14t support
- 10-100x faster installs (matters for UX when user clicks "Install")
- Single static binary — no dependency on pip being installed in the Python distribution
- ~30MB — trivial next to the ~390MB bundled rustc
- Better dependency resolution
- Could remove pip from python-dist to save bundle space

---

## Phase 2A: Bundle uv + sys.path Wiring

### Step 1: Download uv (`scripts/setup-uv.sh`)
- **Create** `scripts/setup-uv.sh` — follows `scripts/setup-rustc.sh` pattern
- Downloads `uv` standalone binary for `aarch64-apple-darwin` from GitHub releases (~30MB)
- Extracts to `uv-dist/` (gitignored)
- **Modify** `.gitignore` — add `uv-dist/`

### Step 2: Copy uv into host app (Xcode build phase)
- **Add** "Copy uv Binary" run script build phase on **ConjureDSP host app target**
- Copies `uv-dist/uv` → `$BUILT_PRODUCTS_DIR/ConjureDSP.app/Contents/Resources/uv-dist/uv`
- Code-signs the binary
- Auto-symlinks `uv-dist/` from main worktree (same pattern as python-dist)
- **Modify** `ConjureDSP.xcodeproj/project.pbxproj`

### Step 3: Add `extra_site_packages` to Rust kernel
- **Modify** `rust/conjure_dsp/src/kernel.rs`
  - Add `extra_site_packages: Option<String>` field to `DSPKernel`
  - Add `set_extra_site_packages(&mut self, path: &str)` method
  - Pass `extra_site_packages.as_deref()` to `PythonBackend::load()`
- **Modify** `rust/conjure_dsp/src/python_backend.rs`
  - Change `load(python_home, script_path)` → `load(python_home, script_path, extra_site_packages: Option<&str>)`
  - Before `PyModule::from_code()`, insert: `sys.path.insert(0, extra_path)`
- **Modify** `rust/conjure_dsp/src/lib.rs`
  - Add FFI: `dsp_kernel_set_extra_site_packages(kernel, path: *const c_char) -> bool`

### Step 4: Wire Swift → Rust
- **Modify** `ConjureDSPExtension/Common/Audio Unit/ConjureDSPExtensionAudioUnit.swift`
  - In `loadPythonScript()`, after resolving pythonHome, call:
    ```swift
    let userPkgs = SharedPythonRuntimeInstaller.userPackagesURL.path
    dsp_kernel_set_extra_site_packages(kernel, userPkgs)
    ```
- **Modify** `ConjureDSP/Model/SharedPythonRuntimeInstaller.swift`
  - Add `static var userPackagesURL: URL` computed property

---

## Phase 2B: Host App Package Manager

### Step 5: PackageInstaller service
- **Create** `ConjureDSP/Model/PackageInstaller.swift`
- `@Observable` class wrapping `uv` subprocess calls
- Core methods:
  - `install(spec: String, source: PackageSource)` — runs `uv pip install --target <user-packages> --python <bundled-python> <spec>`
  - `uninstall(packageName: String)` — removes directory from user-packages
  - `listInstalled() -> [InstalledPackage]` — reads manifest.json
- After install, walks user-packages for `.so`/`.dylib` files and ad-hoc signs them (follows `PendingExportHandler.codeSign()` pattern at `ConjureDSP/Model/PendingExportHandler.swift:119`)
- Writes/updates `user-packages/manifest.json` tracking installed packages, source, version, date
- Finds bundled uv at `Bundle.main.resourceURL/uv-dist/uv`, falls back to system `uv`
- Source types:
  - **PyPI:** `uv pip install <name>`
  - **GitHub:** `uv pip install git+https://...` (macOS ships git via Xcode CLT)
  - **Local:** `uv pip install /path/to/package` (host app is unsandboxed)

### Step 6: PackageManagerView UI
- **Create** `ConjureDSP/Views/PackageManagerView.swift`
- Toolbar button in host app → opens sheet
- Lists installed packages (bundled ones marked "(bundled)", no uninstall)
- Install form: source picker (PyPI/GitHub/Local segmented), text field (or NSOpenPanel for local), Install button
- Progress indicator during install, error display
- **Modify** `ConjureDSP/ContentView.swift` — add toolbar button
- **Modify** `ConjureDSP/ConjureDSPApp.swift` — instantiate PackageInstaller if needed

---

## Phase 3: Requirements Files

Requirements are declared in a separate file alongside the script, named `<script-name>-requirements.txt`. Standard pip requirements format (one package per line). Examples:

- User preset: `~/Library/.../Presets/My Filter.py` → `My Filter-requirements.txt`
- Factory preset: `ConjureDSPExtension/Resources/preset_delay.py` → `preset_delay-requirements.txt`

### Step 7: Requirements file discovery
- **Modify** `ConjureDSPExtension/Model/PresetManager.swift`
  - Add `requirementsURL(for preset: Preset) -> URL?` — returns sibling `-requirements.txt` path
  - Add `loadRequirements(for preset: Preset) -> [String]?` — reads and parses requirements file
  - When saving user presets, also save/update requirements file if provided

### Step 8: Enhanced error messages for missing imports
- **Modify** `ConjureDSPExtension/UI/ConjureDSPExtensionMainView.swift`
  - When error contains `ModuleNotFoundError` or `No module named`, append guidance:
    "Open ConjureDSP app → Packages to install it."

### Step 9: AI integration
- **Modify** `ConjureDSPExtension/AI/AnthropicProvider.swift`
  - Update system prompt: "If your script needs packages beyond numpy/scipy, the user should create a `<script-name>-requirements.txt` file alongside the script with one package per line."
  - When AI generates a script that would need extra packages, mention this in the response

---

## Files Summary

| File | Action | Phase |
|------|--------|-------|
| `scripts/setup-uv.sh` | Create | 2A |
| `.gitignore` | Modify | 2A |
| `ConjureDSP.xcodeproj/project.pbxproj` | Modify | 2A |
| `rust/conjure_dsp/src/kernel.rs` | Modify | 2A |
| `rust/conjure_dsp/src/python_backend.rs` | Modify | 2A |
| `rust/conjure_dsp/src/lib.rs` | Modify | 2A |
| `ConjureDSPExtension/Common/Audio Unit/ConjureDSPExtensionAudioUnit.swift` | Modify | 2A |
| `ConjureDSP/Model/SharedPythonRuntimeInstaller.swift` | Modify | 2A |
| `ConjureDSP/Model/PackageInstaller.swift` | Create | 2B |
| `ConjureDSP/Views/PackageManagerView.swift` | Create | 2B |
| `ConjureDSP/ContentView.swift` | Modify | 2B |
| `ConjureDSPExtension/Model/PresetManager.swift` | Modify | 3 |
| `ConjureDSPExtension/UI/ConjureDSPExtensionMainView.swift` | Modify | 3 |
| `ConjureDSPExtension/AI/AnthropicProvider.swift` | Modify | 3 |

## Verification

1. **Rust tests:** `cd rust && cargo test -- --test-threads=1` — new tests for `set_extra_site_packages` and sys.path insertion
2. **uv setup:** Run `scripts/setup-uv.sh`, verify `uv-dist/uv` exists and runs
3. **Xcode build:** `xcodebuild build` succeeds with new build phase
4. **End-to-end:** Install a package via host app UI → write a script importing it → run in AU extension → verify it works
5. **Uninstall:** Remove package → verify import fails with clear error message
6. **Code signing:** Verify `.so` files in user-packages are signed (`codesign -v`)
7. **Swift tests:** `xcodebuild test` — existing tests still pass

## Open Questions

1. **Bundle size budget** — uv adds ~30MB. Current app is already ~530MB (Python + rustc). Acceptable?
2. **Shared runtime versioning** — If ConjureDSP updates Python (3.14→3.15), user packages are lost. Consider migration strategy.
3. **Package removal** — `uv pip uninstall` with `--target` may not work cleanly. May need manual directory deletion.
4. **PYTHONDONTWRITEBYTECODE** — Currently set globally. For user-packages (unsigned), `.pyc` files are beneficial. Consider only suppressing bytecode for the sealed app bundle path.
5. **Export and user packages** — Exported AUs use the shared runtime but should NOT rely on user packages (missing on other machines). Export pipeline should warn if script has requirements beyond numpy/scipy.
