# Python Package Management

> **Note:** This document supersedes the earlier per-preset isolated environments design. The approach was simplified to a global shared package directory after recognizing that per-preset isolation added complexity without proportional benefit for the typical DSP use case.

## Context

Python DSP scripts can currently only use numpy, scipy, and the stdlib. This feature adds:

1. **Global `user-packages/` directory** -- one shared package directory for all presets at `~/Library/Application Support/ConjureDSP/user-packages/`
2. **Package manager UI** in the AU extension -- search PyPI, install/uninstall packages, view installed packages
3. **Companion app as installer** -- installs from within DAW via App Group file signaling, no context switch
4. **Vendored exports** (future) -- optional at export time, auto-detected via static import analysis + user selection

## Architecture

```
AU Extension (sandboxed in DAWs)           Companion App (unsandboxed)
+----------------------------------+       +-----------------------------+
| PackageInstallManager            |       | PackageInstaller            |
|   writes install-request.json ---------->|   reads request             |
|   polls for result.json     <------------|   runs bundled `uv`         |
|                                  |       |   code-signs .so files      |
| Rust kernel: sys.path injection  |       |   writes result.json        |
|   dsp_kernel_set_extra_site_pkgs |       +-----------------------------+
|                                  |
| PackageManagerView (toolbar)     |
|   search PyPI, install, uninstall|
+----------------------------------+
          |
          v
~/Library/Application Support/ConjureDSP/
  PythonRuntime-3.14/          <- bundled: interpreter, stdlib, numpy, scipy
  user-packages/               <- user-installed packages (shared by all presets)
```

## How It Works

### sys.path Injection (Rust)

Before the initial Python script load, the AU calls `dsp_kernel_set_extra_site_packages(kernel, path)` to prepend the `user-packages/` directory to `sys.path`. This is idempotent and takes effect immediately via `PythonBackend::inject_site_packages()`, so user-installed packages are importable by any preset.

### Package Installation Flow

1. User opens Packages panel in AU toolbar (shippingbox icon)
2. Searches PyPI or types a package spec (e.g. `pedalboard==0.9.16`)
3. Clicks Install -> AU writes `package-install-request.json` to App Group container
4. Companion app detects request in its 500ms polling loop
5. Companion app runs: `uv pip install --target <user-packages> --python <shared-runtime-python-bin> <packages>`
6. Companion app code-signs any `.so`/`.dylib` files
7. Companion app writes `package-install-result.json` to App Group
8. AU detects result, refreshes installed packages list

### Uninstall

Same flow but with `package-uninstall-request.json`. Companion app reads `top_level.txt` from `.dist-info` to discover actual import directory names (handles cases like Pillow->PIL, beautifulsoup4->bs4), then removes package directory, `.dist-info`, and `.data` dirs.

### Vendored Exports (Future)

At export time:
1. Static analysis scans the script for `import X` / `from X import Y` statements
2. Filters against stdlib + numpy + scipy to identify third-party imports
3. Pre-selects matching packages from `user-packages/`
4. User can adjust the selection (add/remove from checklist)
5. Selected packages copied into `Resources/vendor-packages/` in the export bundle
6. Export template checks for `vendor-packages/` at load time (highest priority in fallback chain)

---

## Implementation Details

### Files Changed

| File | Purpose |
|------|---------|
| `rust/conjure_dsp/src/python_backend.rs` | `inject_site_packages()` static method, inject into sys.path |
| `rust/conjure_dsp/src/kernel.rs` | `set_extra_site_packages()` delegates to PythonBackend |
| `rust/conjure_dsp/src/lib.rs` | New FFI: `dsp_kernel_set_extra_site_packages()` |
| `rust/include/conjure_dsp.h` | Auto-generated C header with new FFI |
| `ConjureDSPExtension/Common/Audio Unit/ConjureDSPExtensionAudioUnit.swift` | Call `set_extra_site_packages` before initial script load |
| `ConjureDSPExtension/Model/PackageInstallManager.swift` | App Group signaling for install/uninstall |
| `ConjureDSPExtension/UI/PackageManagerView.swift` | Package manager UI panel |
| `ConjureDSPExtension/UI/PresetToolbar.swift` | Packages button in toolbar |
| `ConjureDSPTerminal/PackageInstaller.swift` | uv-based package installer service |
| `ConjureDSPTerminal/ConjureDSPTerminalApp.swift` | Integrate PackageInstaller into file-watch loop |
| `ConjureDSP/Model/SharedPythonRuntimeInstaller.swift` | `userPackagesURL` property |
| `scripts/setup-uv.sh` | Download uv binary |
| `.gitignore` | Add `uv-dist/` |

### Prerequisites

- Run `scripts/setup-uv.sh` once to download the `uv` binary (~31MB)
- Companion app must be running for package installs to work

### Key Design Decisions

- **Global over per-preset**: One `user-packages/` directory shared by all presets. Simpler than per-preset isolation; version conflicts are unlikely for DSP packages and this matches standard Python workflows.
- **No in-script REQUIREMENTS**: Users manage packages through the UI panel, not metadata in scripts. The AU helps identify what to vendor at export time via static import analysis.
- **Companion app as installer**: AU extension is sandboxed in DAWs and cannot run subprocesses. The companion app runs outside the sandbox and uses App Group file signaling (same pattern as the Claude Code terminal).
- **uv over pip**: 10-100x faster installs, single static binary, first-class free-threaded Python 3.14t support.
- **Shared runtime for --python**: Install requests use the shared runtime path at `~/Library/Application Support/ConjureDSP/PythonRuntime-3.14/` (not the bundled python-dist resource) so uv has access to a real Python binary for wheel compatibility checks.

### What's Not Yet Implemented

- Vendored exports (import analysis + export UI + export template changes)
- Community browser badges for presets with third-party dependencies
- Auto-launch companion app from sandbox via custom URL scheme
