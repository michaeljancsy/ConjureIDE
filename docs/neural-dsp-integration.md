# Neural DSP Integration

Run neural network models (amp captures, effect emulations, learned processors) inside ConjureDSP scripts for real-time audio inference.

## Constraints

- Inference must complete within the audio buffer deadline (~1–5ms at 256 samples)
- AU extension sandbox limits file access — models need to live alongside presets or in the App Group container
- Python backend has numpy/scipy; WASM backend is too slow for NN inference
- Bundled Python is free-threaded 3.14 — library compatibility must be verified
- Small models (NAM captures, ~few hundred KB) are feasible for real-time CPU inference; large models (transformers) are not

## Option A: Low Complexity — ONNX Runtime in Python

Add `onnxruntime` to the bundled Python environment. Users load `.onnx` models in their scripts.

### Implementation

1. Add `onnxruntime` to `setup-python.sh` (`pip install onnxruntime`)
2. Add a `conjuredsp.nn` helper module:
   - `load_model(path)` — load and cache an ONNX session
   - `run(model, buffer)` — run inference on a numpy audio buffer
   - Session caching across render calls (avoid re-loading every callback)
3. Add a `MODEL` metadata key in scripts (like `PARAMS`) pointing to a model file bundled alongside the preset
4. Ship 1–2 example presets (amp capture, saturator)

### User script example

```python
from conjuredsp.nn import load_model

MODEL = "amp_capture.onnx"  # bundled with preset

model = load_model(MODEL)  # cached across render calls

def process(inputs, outputs, frame_count, sample_rate, params):
    for ch in range(len(inputs)):
        outputs[ch][:frame_count] = model.run(inputs[ch][:frame_count])
```

### Pros

- Minimal code changes to existing codebase
- ONNX is universal — users train in PyTorch/TensorFlow and export
- ~50MB size addition for onnxruntime
- Real-time feasible for small models on CPU

### Cons

- Python-only (no Rust/WASM path)
- onnxruntime may not have free-threaded Python 3.14 wheels yet — **must verify**
- Model file management (bundling, sandbox access) needs design
- No hardware acceleration beyond CPU

### Effort

~1–2 days

### Open questions

- Does onnxruntime ship wheels for free-threaded Python 3.14? If not, can it be built from source?
- How are model files discovered at runtime inside the AU sandbox? Same directory as preset file? App Group container?

## Option B: High Complexity — Native Rust NN Backend + Model Ecosystem

Rust-native inference engine exposed to both Python and Rust scripts, with model management and optional CoreML acceleration.

### Implementation

1. Add **tract** (Rust ONNX/NNEF inference library) to the Rust crate — runs natively, no Python dependency
2. New FFI functions: `dsp_kernel_load_model(path)`, `dsp_kernel_run_model(model_id, buffer, len)` — model inference integrated into the render pipeline
3. `conjuredsp` library gains NN primitives in both languages:
   - `NeuralModel` — load/cache/run inference
   - `NeuralAmpModel` — specialized for guitar amp captures (NAM-compatible)
   - `NeuralBlock` — generic block for chain-of-effects style usage
4. **Model file management**: models stored alongside presets, referenced by `MODEL` metadata, sandboxed via App Group container
5. **CoreML backend** (stretch): convert ONNX → CoreML for Apple Silicon Neural Engine acceleration
6. **Format support**: ONNX, NAM (`.nam` JSON), RTNeural JSON
7. **Export support**: models bundled into exported standalone AUs
8. Factory presets: amp model, tube saturator, vintage compressor emulation

### Architecture

```
Script (Python or Rust)
    → conjuredsp.nn API (Python module or Rust crate)
    → Rust FFI
    → tract / CoreML
    → inference result (numpy array or WASM buffer)
```

The model always runs in native Rust regardless of script language:
- **Python scripts**: call `conjuredsp.nn` which calls through pyo3 → Rust FFI → tract
- **Rust/WASM scripts**: call an imported host function (WASM import) that runs tract on the host side, bypassing WASM's performance limitations

### User script examples

**Python:**
```python
from conjuredsp.nn import NeuralAmpModel

MODEL = "mesa_boogie.onnx"

amp = NeuralAmpModel(MODEL)

PARAMS = {
    "gain": {"min": 0, "max": 1, "default": 0.5},
    "mix": {"min": 0, "max": 1, "default": 1.0},
}

def process(inputs, outputs, frame_count, sample_rate, params):
    for ch in range(len(inputs)):
        dry = inputs[ch][:frame_count]
        wet = amp.process(dry, gain=params["gain"])
        outputs[ch][:frame_count] = dry * (1 - params["mix"]) + wet * params["mix"]
```

**Rust:**
```rust
use conjuredsp::*;
use conjuredsp::nn::NeuralModel;

setup!();
params! {
    GAIN = param(0.0, 1.0).default(0.5).name("Gain"),
    MIX  = mix(),
}

static MODEL: NeuralModel = NeuralModel::new("mesa_boogie.onnx");

#[unsafe(no_mangle)]
pub extern "C" fn process() {
    let ctx = ctx();
    for ch in 0..ctx.channels() {
        for i in 0..ctx.frames() {
            let dry = ctx.input(ch, i);
            let wet = MODEL.process_sample(dry, ctx.param(GAIN));
            ctx.set_output(ch, i, lerp(dry, wet, ctx.param(MIX)));
        }
    }
}
```

### Pros

- Works for both Python and Rust scripts
- Native Rust performance (no Python overhead in inference path)
- CoreML acceleration available on Apple Silicon
- Model files export with standalone AUs
- Supports multiple model formats (ONNX, NAM, RTNeural)

### Cons

- Significant implementation effort
- tract adds ~5–10MB to binary size
- CoreML integration is complex (model conversion, async inference)
- Model training and sourcing is a separate problem (out of scope)
- WASM host-function imports add complexity to the WASM backend

### Effort

~2–3 weeks

### Open questions

- Which model formats matter most? ONNX is universal, but NAM `.nam` files are popular in the guitar community
- Is CoreML worth the complexity? CPU inference via tract may be fast enough for small models
- How to handle models that are too large/slow for real-time? Graceful degradation vs rejection at load time?
- Should model loading be async (like WASM compilation) with a compilation/loading status indicator?

## Recommendation

Start with **Option A** to validate demand and real-time feasibility. The critical unknown is onnxruntime compatibility with free-threaded Python 3.14 — check that first.

If onnxruntime doesn't work with 3.14t, the fallback middle path is: add **tract** to the Rust crate with a thin Python wrapper via pyo3 (Option B's core inference engine, but exposed only to Python initially, without the full model ecosystem). This sidesteps the Python compatibility issue while keeping scope small.

Option B becomes worthwhile once there's validated user demand and a clear picture of which model formats/use cases matter most.
