# Per-Preset Package Requirements

## Context

Python DSP scripts can currently only use numpy, scipy, and the stdlib. The existing `docs/python-package-management.md` plans user-installable packages (Phases 2–3) with sidecar `-requirements.txt` files and a host-app-only install flow. This design replaces that approach with:

1. **In-script `REQUIREMENTS`** metadata (like PARAMS/LATENCY) — self-contained, no sidecar files
2. **Companion app as package installer** — installs from within DAW, no context switch to host app
3. **Per-preset isolated environments** — each preset gets its own package directory, eliminating version conflicts
4. **Exact version pinning** — reproducible builds, no "works on my machine"
5. **Vendored exports** — optional at export time, makes exports portable to machines without ConjureDSP
6. **Configurable Python path** — exported AUs have a settings field pointing to the Python environment, overridable by power users or non-ConjureDSP users

---

## Declaration

Scripts declare dependencies as a Python list with exact version pins:

```python
REQUIREMENTS = ["pedalboard==0.9.16", "resampy==0.4.3"]

PARAMS = {
    "threshold": db(min=-40, max=0, default=-20),
}

def process(inputs, outputs, frame_count, sample_rate, params):
    import pedalboard
    ...
```

- **Exact versions only** (`==`). ConjureDSP enforces this at install time — if the user writes `>=`, the install resolves and pins to the exact version installed.
- Follows the established in-script metadata pattern (PARAMS, LATENCY, PARAM_NAMES).
- Extracted by Rust at script load time, same as PARAMS in `python_backend.rs`.
- Rust/WASM presets don't need this — they compile to self-contained WASM.
- Factory presets must NOT declare external requirements (must work out of the box everywhere).

---

## Per-Preset Isolated Environments

Each preset with REQUIREMENTS gets its own package directory. All environments share the underlying Python 3.14t interpreter + stdlib + numpy/scipy.

```
~/Library/Application Support/ConjureDSP/
  PythonRuntime-3.14/                    # shared: interpreter, stdlib, numpy, scipy, conjuredsp
  Environments/
    <preset-id>/                         # one directory per preset
      resampy/
      soundfile/
    <another-preset-id>/
      pedalboard/
```

**Why per-preset isolation:**
- Eliminates version conflicts entirely — two presets can pin different versions of the same package
- Storage cost is negligible (most DSP packages are <500KB; even with duplication, total is small relative to the ~530MB app)
- Simple mental model — each preset is fully self-contained

**One environment per preset.** No sharing between presets, even if their REQUIREMENTS are identical. This keeps cleanup trivial: when a preset is deleted, its environment directory is deleted too. No reference counting needed.

**Environment identity:** Keyed by the preset's existing ID (e.g., `user:My Filter.py`, sanitized to a filesystem-safe name).

**REQUIREMENTS normalization:** Rust sorts the extracted REQUIREMENTS list after extracting it from the Python module (before computing anything from it). The user's script stays as-written; normalization happens at the extraction layer.

**Transitive dependencies:** `uv` resolves the full dependency tree. REQUIREMENTS only lists direct dependencies; `uv pip install --target` installs transitive deps automatically into the environment directory.

**On script load**, Rust receives the environment path and inserts it into `sys.path` before executing the script:
```rust
// sys.path = [preset_env_path, shared_runtime_site_packages, stdlib, ...]
sys.path.insert(0, preset_env_path);
```

---

## Package Installation — Companion App

The ConjureDSPTerminal companion app handles installation. It already runs outside the sandbox and communicates with the AU via App Group file signaling.

**Flow:**
```
User loads preset with REQUIREMENTS in DAW
  ↓
AU extracts REQUIREMENTS, checks if environment exists with all pinned packages
  ↓
Missing packages → AU shows prompt: "This preset needs pedalboard==0.9.16. [Install]"
  ↓
User clicks Install
  ↓
AU writes request to App Group: package-install-request.json
  {"requirements": ["pedalboard==0.9.16"], "environmentId": "<hash>"}
  ↓
Companion app detects request (existing 500ms file-watch loop)
  ↓
Companion app runs: uv pip install --target <env-path> --python <bundled> pedalboard==0.9.16
  ↓
Companion app code-signs any .so files in the environment
  ↓
Companion app writes: package-install-result.json
  {"success": true, "environmentId": "<hash>", "installed": ["pedalboard==0.9.16"]}
  ↓
AU detects result, reloads script — works now
```

**Companion app not running?** AU detects this via absence of port file / failed health check. First attempt: auto-launch via custom URL scheme (`conjuredsp-terminal://install`). AU extensions may be able to open URL schemes even from sandbox — needs testing. Fallback if blocked: show message "Start ConjureDSP Terminal to install packages."

**Host app** remains a secondary interface — useful for browsing installed environments, cleaning up unused ones, manual package management. But the companion app is the primary install path.

---

## Exported AUs

### Vendor choice at export time

The exporter chooses whether to vendor packages into the export bundle:

```
┌──────────────────────────────────────────┐
│ Export "Warm Tape Saturator"             │
│                                          │
│ ☑ Include packages          +2.1 MB     │
│   • resampy==0.4.3           (210 KB)   │
│   • soundfile==0.12.1        (1.9 MB)   │
│                                          │
│ Estimated export size:       17.1 MB     │
│                                          │
│ [Export]                                 │
└──────────────────────────────────────────┘
```

- **Vendored** (checkbox on): packages copied into `Resources/vendor-packages/`, code-signed. Export is portable — works on any machine with a Python 3.14t runtime. Good for sharing.
- **Not vendored** (checkbox off): lightweight export, behaves identically to a regular ConjureDSP preset. Relies on the managed environment on the recipient's machine. Good for personal use on the same machine.

### Package resolution at load time (exported AU)

Fallback chain:
1. **Vendored packages** — `vendor-packages/` inside the export bundle (if present, always wins)
2. **ConjureDSP managed environment** — per-preset environment at `~/Library/Application Support/ConjureDSP/Environments/<hash>/`
3. **User-configured Python path** — settings string in the exported AU's UI

### Settings string (Python environment path)

Exported AUs include a text field in their UI where the user can override the Python environment path. Stored in `runtime-config.json`.

- **Default:** Points to ConjureDSP's managed runtime (`~/Library/Application Support/ConjureDSP/PythonRuntime-3.14/`)
- **Override use cases:**
  - Recipient doesn't have ConjureDSP → points to their own Python 3.14t install
  - Power user with a custom environment
  - Non-vendored export on a different machine

### Error messages

Errors must be descriptive and help less-Python-savvy users. Examples:

**No Python runtime found (no ConjureDSP, no override):**
```
Python 3.14 runtime not found.

Install ConjureDSP (free) to set up the runtime automatically,
or set a custom Python path in this plugin's settings.

Settings → Python Environment Path → /path/to/python3.14t
```

**Python found but missing packages (non-vendored, no managed environment):**
```
Missing packages: resampy==0.4.3, soundfile==0.12.1

If you have ConjureDSP installed, load this preset there to
install packages automatically.

Or install manually:
  pip install resampy==0.4.3 soundfile==0.12.1

Or set a Python environment path that has these packages:
  Settings → Python Environment Path
```

**Vendored export, Python found:** Just works, no errors.

---

## What Changes From the Existing Plan

| `docs/python-package-management.md` (current) | Revised |
|---|---|
| Sidecar `-requirements.txt` files (Phase 3) | In-script `REQUIREMENTS = [...]` |
| Global `user-packages/` directory | Per-preset isolated environments at `Environments/<hash>/` |
| Version ranges allowed | Exact version pins enforced (`==`) |
| Host app only for package install (Phase 2B) | Companion app as primary installer via App Group signaling |
| Exports can't use extra packages | Exports optionally vendor packages; settings string for Python path |
| No conflict handling | No conflicts possible (per-preset isolation) |

Phase 2A infrastructure (sys.path wiring, Rust `extra_site_packages` FFI) remains relevant and is reused.

---

## Implementation Sketch

### Rust (`python_backend.rs`, `kernel.rs`, `lib.rs`)
- Extract `REQUIREMENTS` list from Python module (same pattern as PARAMS)
- Cache as JSON string in kernel
- New FFI: `dsp_kernel_requirements_json()` — returns JSON array or null
- Existing Phase 2A FFI `dsp_kernel_set_extra_site_packages()` used to set per-preset environment path

### Swift AU Extension (`ConjureDSPExtensionAudioUnit.swift`)
- After loading script, read requirements JSON via FFI
- Compute environment hash from sorted pinned requirements
- Check if `Environments/<hash>/` exists and is populated
- If missing: show install prompt in UI
- On install click: write `package-install-request.json` to App Group
- Watch for `package-install-result.json`, reload script on success

### Companion App (`ConjureDSPTerminal/`)
- New `PackageInstaller` service alongside PTYManager, WebSocketServer
- Bundles `uv` binary (downloaded via `scripts/setup-uv.sh`, copied into companion app Resources)
- Watches App Group for `package-install-request.json`
- Runs `uv pip install --target <Environments/preset-id/> --python <bundled> <packages>`
- Code-signs `.so`/`.dylib` files post-install
- Writes `package-install-result.json`
- Register custom URL scheme `conjuredsp-terminal://` for auto-launch attempts from AU extension

### Export (`ExportManager.swift`)
- Read REQUIREMENTS from loaded script metadata
- If "include packages" checked: copy environment directory into `Resources/vendor-packages/`, code-sign `.so` files
- Write `requirements` and `vendorPackagesPath` into `runtime-config.json`
- If requirements aren't installed locally, block export: "Install packages first"

### Export Template (`ExportAUAudioUnit.swift`)
- Load time: check for `vendor-packages/` in bundle (priority 1), then managed environment (priority 2), then user-configured path (priority 3)
- Settings UI: text field for Python environment path override, stored in UserDefaults or runtime-config.json
- Descriptive errors with actionable guidance for each failure mode

### Community Browser (`CommunityPresetStore.swift`)
- Regex-extract REQUIREMENTS from script source for display
- Show "Requires: X, Y" badge on presets with dependencies
- On install: prompt to install packages alongside the preset

### Cleanup (`PresetManager.swift`)
- On preset delete: also delete `Environments/<preset-id>/` directory
- On preset rename: rename the environment directory to match the new preset ID

### No changes needed to:
- `PersonalRepoSync.swift` (requirements travel inside the script)
- Preset file format (still bare `.py` files)
- `PresetMetadata` / `GitHubModels.swift` (display metadata unchanged)

---

## Open Questions

1. **Auto-launch from sandbox** — Can the AU extension open a custom URL scheme (`conjuredsp-terminal://`) from within a DAW's sandbox? Needs testing in Logic/Ableton. If not, fallback is a manual-launch prompt.
