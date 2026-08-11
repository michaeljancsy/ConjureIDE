# ConjureDSP

An AUv3 audio effect plugin for macOS where the DSP is a script you can edit
while audio runs. Write the processing in **Python** (bundled free-threaded
Python 3.14 with numpy/scipy, instant reload) or **Rust** (compiled to WASM by
a bundled rustc and executed in wasmtime), live inside any DAW.

## Features

- **Two DSP languages, one parameter system** — Python scripts load instantly;
  Rust scripts compile to `wasm32-wasip1` with fuel-metered execution. Both
  declare up to 16 rich parameters (ranges, units, log curves, toggles,
  choices) that appear as real, automatable DAW parameters.
- **`conjuredsp` DSP library** for both languages: biquads, delay lines, LFOs,
  parameter builders, dB/time utilities, and hardware-accelerated vector math
  (Accelerate-backed in WASM, numpy-backed in Python).
- **Neural Amp Modeler (NAM) inference** in both languages, with a built-in
  browser for [TONE3000](https://www.tone3000.com) tone captures.
- **Preset bundles with custom UIs** — presets are `.cdp` bundles that can
  ship an HTML/JS interface (rendered in place of the stock sliders) built on
  the `cdp-ui` web-component library, with hot reload while you edit.
- **In-plugin coding agent** — a terminal running Claude Code, wired to the
  plugin through an in-process MCP server (compile/run scripts, set
  parameters, read audio state, author preset UIs).
- **Monaco editor** (VS Code's editor) embedded in the plugin.
- **Spectrogram view** — input, output, and difference modes.
- **Git-backed preset library** — every save is a commit; optional push to
  your own GitHub repo.
- **Export presets as standalone AUv3 plugins** that run without ConjureDSP
  installed.

## Installing

1. Download the DMG from [conjuredsp.com](https://conjuredsp.com), open it,
   and drag ConjureDSP to Applications.
2. Open ConjureDSP once. macOS registers the AUv3 plugin at first launch;
   until then it will not appear in any DAW.
3. Restart your DAW and insert ConjureDSP from Audio Units > Effects.

## Building

Prerequisites: macOS 15 (Sequoia)+, Xcode, a Rust toolchain (`rustup`,
`cargo`) with the `aarch64-apple-darwin` target, `cbindgen`
(`cargo install cbindgen`), and an Apple Developer team (a free account
works for local development).

```bash
# One-time setup — downloads the bundled runtimes and editor assets
(cd rust && ./setup-python.sh)   # free-threaded Python 3.14 + numpy + scipy (~100 MB)
./scripts/setup-rustc.sh         # standalone rustc + wasm32-wasip1 sysroot
./scripts/setup-monaco.sh        # Monaco editor
./scripts/setup-xterm.sh         # xterm.js terminal UI
./scripts/setup-uv.sh            # uv package manager

# One-time signing config — set your Apple development team id
cp Config/Local.xcconfig.template Config/Local.xcconfig
$EDITOR Config/Local.xcconfig

# Build
xcodebuild -project ConjureDSP.xcodeproj -scheme ConjureDSP build
# …or open ConjureDSP.xcodeproj in Xcode and run the ConjureDSP scheme
```

Running the ConjureDSP host app registers the AU extension with macOS; after
that the plugin appears in any AUv3 host (Logic Pro, GarageBand, Reaper, …).
See [CONTRIBUTING.md](CONTRIBUTING.md) for the full development guide,
including tests and signing details.

## Writing a DSP script

Python:

```python
from conjuredsp import db

PARAMS = {"gain": db(min=-40, max=6, default=0)}

def process(ctx):
    # ctx.inputs / ctx.outputs are (channels, frame_count) float32 arrays
    ctx.outputs[:] = ctx.inputs * (10.0 ** (ctx.params["gain"] / 20.0))
```

Rust:

```rust
use conjuredsp::*;

params! { GAIN = db().min(-40.0).max(6.0).default(0.0) }

process! { ctx =>
    let gain = db_to_gain(ctx.param(GAIN));
    for ch in 0..ctx.channels() {
        for i in 0..ctx.frames() {
            ctx.set_output(ch, i, ctx.input(ch, i) * gain);
        }
    }
}
```

The `ctx` object also exposes `sample_rate`, `transport` (BPM, beat,
playhead), `sidechain`, `telemetry` (feed custom UI meters/scopes), and
`state` (per-bundle persistent values). In-plugin documentation covers the
full API (the agent reaches the same docs through the `get_docs` MCP tool).

## Architecture

**Swift/SwiftUI** implements the plugin UI, host app, and AU render block.
**Rust** implements the DSP kernel, embedding Python via pyo3 and WASM via
wasmtime behind a common backend trait, bridged to Swift over C FFI. The
**ConjureDSPTerminal** companion app runs the Claude Code CLI and other
helpers that the sandboxed AU extension cannot spawn itself, communicating
through an App Group container. `AGENTS.md` documents the full architecture.

## Telemetry

Builds from source have **no telemetry**: analytics (Mixpanel) and crash
reporting (Sentry) initialize only when a token/DSN is supplied at build time
via `Config/Local.xcconfig`, and that file is empty by default. Official
releases distributed from conjuredsp.com set both.

## Updates

Official builds check `updates.conjuredsp.com` for Sparkle auto-updates,
verified against the public key in `ConjureDSP/Info.plist`. If you fork and
distribute your own builds, replace `SUFeedURL` and `SUPublicEDKey` with your
own feed and key (or remove them).

## License

ConjureDSP is free software, licensed under the
[GNU General Public License v3.0](LICENSE). Portions derive from Apple sample
code and other projects — see [ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md).

ConjureDSP is not affiliated with or endorsed by TONE3000; tone captures
downloaded through the integration carry their capturers' own licenses.

To report a security issue, see [SECURITY.md](SECURITY.md).
