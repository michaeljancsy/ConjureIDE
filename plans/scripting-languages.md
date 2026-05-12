# Support Compiled DSP Languages (C, C++, Rust) via WASM

## Problem
Currently the DSP kernel only supports Python scripts. While Python with numpy is productive for prototyping, compiled languages (C, C++, Rust) offer dramatically better performance and real-time safety (no GC). The goal is to let users write DSP code in C, C++, or Rust alongside the existing Python support.

## Current State

### Rust Kernel Architecture (`rust/test_plugin_dsp/src/kernel.rs`)
The `DSPKernel` struct is tightly coupled to Python:
- `py_process_fn: Option<Py<PyAny>>` — cached Python `process()` function
- `py_input_arrays` / `py_output_arrays` — pre-allocated numpy float32 arrays
- `load_script()` — reads `.py` file, compiles via `PyModule::from_code()`, caches `process()`
- `process_with_python()` — copies buffers to numpy, calls Python, copies back
- `benchmark_process()` — generates sine test signal, times Python execution

### FFI Surface (`rust/test_plugin_dsp/src/lib.rs`)
- `dsp_kernel_load_script(kernel, python_home, script_path) -> bool`
- `dsp_kernel_process(kernel, inputs, outputs, ch_count, frame_count)`
- `dsp_kernel_benchmark_process(kernel) -> f64`

### AUv3 Extension Sandboxing
- `ENABLE_APP_SANDBOX = YES` in Xcode project
- Host app has `inter-app-audio` entitlement
- Extension has no entitlements file currently

## Research: Why WASM

Four approaches were evaluated for running compiled DSP code at runtime:

| Approach | Verdict | Reason |
|----------|---------|--------|
| **dlopen (.dylib)** | Not viable | macOS hardened runtime + sandbox blocks loading unsigned dylibs. Requires `disable-library-validation` entitlement, incompatible with App Sandbox. |
| **WASM (wasmtime)** | **Recommended** | WASM modules are data, not native code — no code signing issues. Fully sandboxed by design. Only needs `allow-jit` entitlement. |
| **In-process JIT (TinyCC/LLVM)** | Not viable | TinyCC has unresolved ARM64 macOS bugs. LLVM JIT works but adds 50-100MB to the binary. |
| **Subprocess compilation + dlopen** | Not viable | Sandbox blocks process spawning from AUv3 extensions. Cannot call `clang`/`rustc` from inside the plugin. |

### WASM via Wasmtime — Key Facts

**Performance**: ~88% of native C++ in JIT mode. AOT pre-compilation approaches native speed. Orders of magnitude faster than Python.

**ARM64 macOS**: Wasmtime has Tier 1 support for `aarch64-apple-darwin`. Cranelift backend handles pointer authentication and BTI.

**Sandbox compatibility**: WASM modules are just data files — the sandbox has no restrictions on reading `.wasm` files. Wasmtime JIT-compiles them in-process using `MAP_JIT` pages, requiring only the `com.apple.security.cs.allow-jit` entitlement (same entitlement browsers use).

**Instantiation**: ~5 microseconds per module instance via Wasmtime's lazy initialization. Hot-reload is effectively instant from the audio thread's perspective.

**Buffer passing**: WASM linear memory is a contiguous byte array the host can read/write directly. Copy ~16KB per stereo render callback (8KB in + 8KB out for 1024 frames) — takes ~1-2 microseconds, negligible.

**No GC**: WASM uses linear memory with deterministic allocation. Fully real-time safe.

### User Toolchains

**C/C++**: Users install [wasi-sdk](https://github.com/WebAssembly/wasi-sdk) (prebuilt clang for wasm32-wasi):
```bash
/path/to/wasi-sdk/bin/clang -O2 -o dsp.wasm dsp.c
```

**Rust**: Users add the target and build:
```bash
rustup target add wasm32-wasip1
cargo build --target wasm32-wasip1 --release
```

**Stretch goal**: Bundle wasi-sdk (~100MB) with the plugin and compile C source in-process, giving users a "paste C code, click Run" experience like Python today.

### Existing Art
- **Cmajor**: Custom DSP language + LLVM JIT by Jules Storer (JUCE creator)
- **Faust (libfaust)**: Functional DSP language + LLVM JIT
- **APE (Audio Programming Environment)**: C++17 JIT via Clang/LLVM in an audio plugin
- **Audio Anywhere**: Research project using WASM via Wasmtime for portable audio plugins

## DSP Function Signature

### C/C++ (compiled to WASM)
```c
#include <stdint.h>

// User implements this function
void process(
    float* input_buffer,     // interleaved: [L0,R0,L1,R1,...] or per-channel with offsets
    float* output_buffer,
    uint32_t channel_count,
    uint32_t frame_count,
    float sample_rate
);

// Optional: called once when the module is loaded
void init(uint32_t max_frames, uint32_t channel_count, float sample_rate);
```

For simplicity, use a flat buffer layout in WASM linear memory. The host allocates input/output regions in the module's memory and passes offsets.

### Rust (compiled to WASM)

> **Note**: this RFC predates PR #308's modernization. The live shape now
> uses the `process! { ctx => … }` macro that emits a zero-arg
> `extern "C" fn process()` — the 5-arg signature shown below is gone.
> See `get_docs("all")` for the current API.

```rust
use conjuredsp::*;
process! { ctx =>
    for c in 0..ctx.channels() {
        for i in 0..ctx.frames() {
            ctx.set_output(c, i, ctx.input(c, i));
        }
    }
}
```

### Example: Gain effect in C
```c
void process(float* input, float* output, uint32_t channels, uint32_t frames, float sr) {
    for (uint32_t ch = 0; ch < channels; ch++) {
        for (uint32_t i = 0; i < frames; i++) {
            uint32_t idx = ch * frames + i;
            output[idx] = input[idx] * 0.5f;
        }
    }
}
```

## Recommended Implementation Plan

### Phase 1: Language Abstraction Layer (Rust)

Refactor the kernel to separate language-specific parts from the common DSP pipeline:

```rust
trait ScriptEngine {
    fn load(&mut self, source: &str) -> Result<(), String>;
    fn initialize(&mut self, channels: u32, max_frames: u32, sample_rate: f64);
    fn process(&mut self, inputs: &[&[f32]], outputs: &mut [&mut [f32]],
               frame_count: u32, sample_rate: f64) -> bool;
    fn benchmark(&mut self, channels: u32, max_frames: u32, sample_rate: f64) -> Option<f64>;
}
```

- Extract Python-specific code from `kernel.rs` into `python_engine.rs`
- `DSPKernel` owns a `Box<dyn ScriptEngine>` and delegates to it
- Common pipeline (bypass, fallback to passthrough, error handling) stays in `kernel.rs`

### Phase 2: WASM Engine

Add wasmtime dependency:
```toml
[dependencies]
wasmtime = "29"  # or latest
```

Implement `WasmEngine`:
```rust
struct WasmEngine {
    engine: wasmtime::Engine,
    instance: Option<wasmtime::Instance>,
    store: wasmtime::Store<()>,
    process_fn: Option<wasmtime::TypedFunc<(i32, i32, u32, u32, f32), ()>>,
    input_offset: u32,   // offset into linear memory for input buffers
    output_offset: u32,  // offset into linear memory for output buffers
}
```

**Buffer management**:
1. On `initialize()`: allocate regions in WASM linear memory for input/output buffers
2. On `process()`: memcpy input audio into WASM memory, call `process()`, memcpy output back
3. Reuse the same memory regions every callback (no per-callback allocation)

**Hot-reload**:
1. Compile new `.wasm` source → `Module::new()` on background thread
2. Create new `Instance` from the module (~5 microseconds)
3. Atomic-swap the instance/function pointers
4. Drop old instance

### Phase 3: Entitlements & FFI

Add `com.apple.security.cs.allow-jit` to the extension's entitlements (create `TestPluginExtension.entitlements` if needed).

Update FFI:
```c
// Load script with explicit language
bool dsp_kernel_load_script_source(DSPKernelRef kernel,
                                    const char* source,
                                    const char* language);  // "python", "c", "cpp", "rust", "wasm"

// Load pre-compiled .wasm binary
bool dsp_kernel_load_wasm(DSPKernelRef kernel,
                           const uint8_t* wasm_bytes,
                           uint32_t wasm_len);
```

For C/C++/Rust source: the plugin needs a compilation step to produce `.wasm` before loading. Options:
- **Phase 3a**: Require users to pre-compile and load `.wasm` files (simplest)
- **Phase 3b** (stretch): Bundle wasi-sdk and compile C source to WASM in-plugin

### Phase 4: Swift Changes

- `TestPluginExtensionAudioUnit.swift`: Add `reloadScript(source:language:)` and `loadWasm(data:)` variants
- `PresetManager.swift`: Support `.wasm`, `.c`, `.cpp`, `.rs` extensions alongside `.py`
- `Preset.swift`: Add `language: ScriptLanguage` enum (`.python`, `.c`, `.cpp`, `.rust`, `.wasm`)
- Factory presets: Add C versions of Passthrough/Tremolo/Bitcrush (as `.wasm` binaries or `.c` source)

### Phase 5: UI Changes

- Language indicator/selector in the toolbar (dropdown or segmented control)
- Syntax highlighting per language:
  - Python: existing `PythonSyntaxHighlighter`
  - C/C++: new `CSyntaxHighlighter` (keywords, types, comments, strings, preprocessor directives)
  - Rust: new `RustSyntaxHighlighter` (keywords, types, lifetimes, macros, comments, strings)
- `HighlightedTextEditor` takes a language parameter
- For `.wasm` files: show a file picker or drag-and-drop instead of a text editor
- Generalize `PythonSyntaxHighlighter.swift` into a `SyntaxHighlighter` protocol with language-specific implementations

### Phase 6: Compilation Pipeline (Stretch Goal)

Bundle wasi-sdk and compile C/C++ source to WASM in-plugin:
1. User writes C code in the editor
2. User clicks "Run"
3. Plugin writes source to temp file
4. Plugin invokes bundled `clang` to compile to `.wasm` (note: this may need to happen in a non-sandboxed helper or the host app — sandbox restricts `posix_spawn`)
5. Plugin loads the `.wasm` via wasmtime

**Sandbox workaround for compilation**: If the AUv3 sandbox blocks process spawning, the compilation step could be done via:
- An XPC service bundled with the host app
- Or compile WASM entirely in the host app and pass to the AU extension

For Rust compilation, users would always need their own toolchain (`rustc` is too large to bundle).

## Key Files to Modify

### Rust
- `rust/test_plugin_dsp/src/kernel.rs` — Extract ScriptEngine trait, refactor to delegate
- `rust/test_plugin_dsp/src/lib.rs` — Add language-aware FFI functions, WASM loading
- New: `rust/test_plugin_dsp/src/python_engine.rs` — Python ScriptEngine impl
- New: `rust/test_plugin_dsp/src/wasm_engine.rs` — WASM ScriptEngine impl
- `rust/test_plugin_dsp/Cargo.toml` — Add wasmtime dependency

### Swift
- `TestPluginExtension/Common/Audio Unit/TestPluginExtensionAudioUnit.swift` — Language-aware script loading
- `TestPluginExtension/Model/PresetManager.swift` — Support multiple file extensions
- `TestPluginExtension/Model/Preset.swift` — Add language enum
- `TestPluginExtension/UI/PresetToolbar.swift` — Language selector
- `TestPluginExtension/UI/PythonSyntaxHighlighter.swift` — Generalize to protocol, add C/Rust highlighters
- `TestPluginExtension/UI/HighlightedTextEditor.swift` — Language parameter
- `TestPluginExtension/UI/TestPluginExtensionMainView.swift` — Pass language through
- New: `TestPluginExtension/TestPluginExtension.entitlements` — `allow-jit` entitlement

### Resources
- New: `TestPluginExtension/Resources/preset_passthrough.wasm` (pre-compiled factory presets)
- New: `TestPluginExtension/Resources/preset_passthrough.c` (C source for reference/editing)

## Testing
- Rust unit tests: WasmEngine load/process/error-handling/hot-reload
- Rust unit tests: ScriptEngine trait dispatch (Python vs WASM)
- Rust unit tests: WASM buffer passing correctness (input/output values)
- Rust unit tests: WASM module with missing `process` export → error
- Swift unit tests: language detection from file extension
- Swift unit tests: `.wasm` preset discovery
- Swift unit tests: fullState roundtrip with language field
- UI tests: language selector visible, C syntax highlighting applied
- Manual: Compile a C gain effect to `.wasm`, load it, verify audio output
- Performance: Benchmark WASM vs Python for the same effect (e.g., bitcrush)
- `auval` validation still passes with `allow-jit` entitlement
