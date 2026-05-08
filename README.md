# ConjureDSP

An AUv3 audio effect plugin for macOS that runs a Python script on every audio render callback. The plugin bundles a free-threaded (no-GIL) Python 3.14 runtime with numpy, allowing you to write DSP in Python with pre-allocated numpy arrays.

When no Python script is loaded or if Python errors at runtime, the plugin falls back to a built-in Rust gain processor.

## How it works

1. A Rust DSP kernel embeds Python 3.14 via [pyo3](https://pyo3.rs/) and [numpy](https://github.com/PyO3/rust-numpy)
2. On plugin init, the kernel loads `process.py` from the app bundle and caches the `process()` function
3. On each audio render callback, input samples are copied into pre-allocated numpy arrays, `process()` is called, and output samples are copied back
4. The Python runtime is free-threaded (PEP 703) — no GIL contention

## Quick start

```bash
# 1. Download bundled Python 3.14 + numpy (one-time, ~100MB)
cd rust && ./setup-python.sh

# 2. Open in Xcode and build
open ConjureDSP.xcodeproj
```

Or build from the command line:

```bash
xcodebuild -project ConjureDSP.xcodeproj -scheme ConjureDSP build
```

### Prerequisites

- macOS 15 (Sequoia)+
- Xcode with Swift 5.0+
- Rust toolchain (`rustup`, `cargo`) with target `aarch64-apple-darwin`
- `cbindgen` (`cargo install cbindgen`)

## Writing a DSP script

Edit `ConjureDSPExtension/Resources/process.py`. The `process()` function is called on every audio render callback:

```python
import numpy as np

def process(ctx):
    for ch_in, ch_out in zip(ctx.inputs, ctx.outputs):
        ch_out[:ctx.frame_count] = ch_in[:ctx.frame_count] * 0.5
```

The single accepted signature is `def process(ctx):`. The host calls
`process()` once per render callback with a `ctx` namespace exposing the
audio buffers and host state.

**`ctx` fields:**
- `ctx.inputs` — list of numpy float32 arrays (one per channel, pre-allocated to `max_frames`)
- `ctx.outputs` — list of numpy float32 arrays (one per channel, pre-allocated to `max_frames`)
- `ctx.frame_count` — number of valid samples this callback (may be less than array length)
- `ctx.sample_rate` — current sample rate (e.g. 44100.0)
- `ctx.params` — dict keyed by parameter name (when a `PARAMS` dict is declared)
- `ctx.transport` — read-only mapping with `bpm`, `beat`, `is_playing`, `time_sig_numerator`, `time_sig_denominator`, `sample_position`
- `ctx.telemetry` — write per-block scalar readouts (when a `TELEMETRY` dict is declared)
- `ctx.state` — read-only mapping over the bundle-private STATE channel
- `ctx.sidechain` — sidechain input arrays (when a sidechain bus is connected)

## Project structure

```
ConjureDSP/                  Host app
ConjureDSPExtension/         AUv3 plugin
  Resources/process.py       Python DSP script
  Common/Audio Unit/         AUAudioUnit subclass + render block
rust/
  conjure_dsp/src/       Rust DSP kernel with embedded Python
  setup-python.sh            Downloads Python 3.14 + numpy
  build-rust.sh              Xcode build phase script
```

## Architecture

**Swift** handles the UI, host app, audio buffer management, and AU render block. **Rust** implements the DSP kernel and embeds Python via pyo3. **Python** runs the user-editable `process.py` script with numpy arrays on each render callback. Swift and Rust communicate through a C FFI bridging header.
