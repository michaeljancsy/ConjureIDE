# Host-Side NAM Inference for WASM Presets

## Context

WASM NAM presets are significantly slower than Python NAM presets despite using the same model and algorithm. The Python path calls NAM inference as native ARM64 code (pyo3 → numpy), while the Rust/WASM path runs NAM inference *inside* the wasmtime sandbox. The fix: when WASM calls `model.process_buffer()`, route it to a host-provided import function that runs NAM inference natively.

## Approach

Add a WASM import function `__conjuredsp_nam_process(input_ptr, output_ptr, frames, channel) -> i32` that the WASM module calls instead of doing inference locally. The host reads audio from WASM memory, runs NAM natively using a `NamModel` stored alongside the WASM backend, and writes results back.

### Key insight
The `NamModel` code already exists in `conjuredsp-rs/src/nam.rs` and compiles for both `wasm32-wasip1` and native targets. We can compile it into the host crate (`conjure_dsp`) directly — no porting needed, just a shared source file.

## Changes

### 1. Add NAM source to the host crate

**`rust/conjure_dsp/src/nam_native.rs`** — New file. Include the `conjuredsp-rs/src/nam.rs` source directly via `include!` or copy the relevant types (`NamModel`, `WaveNetModel`, `LstmModel`, `from_binary`). The host needs `NamModel::from_binary()` and `NamModel::process_buffer()`.

Since `nam.rs` uses `extern crate alloc` and `fast_expf`/`tanhf` (no external deps after the libm removal), it should compile natively without changes. The only issue: `nam.rs` is written for `no_std` (uses `alloc::vec`), but the host crate uses `std`. We can gate this with `#[cfg]` or just re-export `alloc` types.

Simplest: symlink or `#[path = "../../conjuredsp-rs/src/nam.rs"] mod nam_native;` — but the `no_std` `extern crate alloc` will conflict with std. Better: copy the file and replace `extern crate alloc; use alloc::vec; use alloc::vec::Vec;` with `use std::vec::Vec;`.

Actually simplest: add a thin wrapper module that does `use std::vec::Vec;` then `include!("../../conjuredsp-rs/src/nam.rs");` — but `include!` won't handle the `extern crate alloc` line.

**Best approach**: Add `conjuredsp-rs` as a dependency of `conjure_dsp` with a native target feature. The `nam.rs` module already compiles for native — it just needs `alloc` available (which `std` provides). Add to `conjure_dsp/Cargo.toml`:

```toml
conjuredsp-rs = { path = "../conjuredsp-rs" }
```

Then use `conjuredsp_rs::NamModel` directly. The `extern crate alloc` in `nam.rs` works fine when `std` is available (std re-exports alloc).

### 2. Change WASM store type to hold NAM state

**`rust/conjure_dsp/src/wasm_backend.rs`**:

Change `Store<()>` → `Store<HostState>` where:

```rust
struct HostState {
    nam_model: Option<conjuredsp_rs::NamModel>,
}
```

Update `Linker<()>` → `Linker<HostState>` throughout.

### 3. Register NAM import function

In `WasmBackend::load()`, after `add_wasi_stubs()`, register:

```rust
linker.func_wrap(
    "env",
    "__conjuredsp_nam_process",
    |mut caller: Caller<'_, HostState>,
     input_ptr: i32, output_ptr: i32, frames: i32, channel: i32| -> i32 {
        let memory = caller.get_export("memory")
            .and_then(|e| e.into_memory())
            .expect("missing memory");

        let n = frames as usize;
        let in_off = input_ptr as usize;
        let out_off = output_ptr as usize;

        // Read input from WASM memory
        let data = memory.data(&caller);
        let mut input_buf = vec![0.0f32; n];
        for i in 0..n {
            let off = in_off + i * 4;
            input_buf[i] = f32::from_le_bytes([data[off], data[off+1], data[off+2], data[off+3]]);
        }

        // Run native NAM inference
        let state = caller.data_mut();
        if let Some(ref mut model) = state.nam_model {
            let mut output_buf = vec![0.0f32; n];
            model.process_buffer(&input_buf, &mut output_buf, channel as usize);

            // Write output back to WASM memory
            let data = memory.data_mut(&mut caller);
            for i in 0..n {
                let bytes = output_buf[i].to_le_bytes();
                let off = out_off + i * 4;
                data[off..off+4].copy_from_slice(&bytes);
            }
            1 // success
        } else {
            0 // no model loaded
        }
    },
).map_err(|e| format!("Failed to register NAM import: {}", e))?;
```

### 4. Update `conjuredsp-rs` NAM to call the import

**`rust/conjuredsp-rs/src/nam.rs`** — Add an `extern "C"` declaration and use it conditionally:

At the top of `nam.rs`, add:

```rust
extern "C" {
    fn __conjuredsp_nam_process(
        input_ptr: *const f32, output_ptr: *mut f32,
        frames: i32, channel: i32,
    ) -> i32;
}
```

Then in `NamModel::process_buffer()`, call the import instead of running inference locally:

```rust
pub fn process_buffer(&mut self, input: &[f32], output: &mut [f32], channel: usize) {
    let result = unsafe {
        __conjuredsp_nam_process(
            input.as_ptr(),
            output.as_mut_ptr(),
            input.len() as i32,
            channel as i32,
        )
    };
    if result != 1 {
        // Fallback: passthrough
        output[..input.len()].copy_from_slice(input);
    }
}
```

But wait — this changes the behavior for the WASM-compiled library. The `conjuredsp-rs` crate is compiled to an rlib for `wasm32-wasip1`. When compiled for WASM, it should use the import. The original in-WASM inference code should be removed since the host handles it.

The `NamModel` struct, `from_binary()`, `WaveNetModel`, `LstmModel` etc. are still needed on the host side (in `conjure_dsp`). On the WASM side, only the import call is needed.

**Revised approach for `conjuredsp-rs`**:

Keep the `NamModel` enum and `from_binary` in the WASM rlib (so `init_nam` still works for the host to parse model data). But replace `process_buffer` with the import call. The host crate gets the full inference code by depending on `conjuredsp-rs` compiled natively.

Actually, rethinking: the host already parses the .nam JSON in Swift and serializes to binary. The host crate needs `from_binary` + inference. The WASM crate needs `from_binary` (for `init_nam`) but NOT inference (since it calls the import).

**Cleaner approach**: Don't change the `conjuredsp-rs` `NamModel::process_buffer` at all. Instead:

1. The host crate (`conjure_dsp`) depends on `conjuredsp-rs` compiled natively
2. During `inject_nam`, the host parses the binary data using `conjuredsp_rs::NamModel::from_binary()` and stores the model in `HostState`
3. The WASM import function `__conjuredsp_nam_process` uses the host-side model
4. In the WASM rlib, `NamModel::process_buffer` is replaced with just the import call
5. `NamModel::from_binary` stays in the WASM rlib so `init_nam` can still parse model data (though the parsed model is unused — the host has its own copy)

Wait, that's wasteful — parsing the model twice. Better:

1. Remove `init_nam` / `from_binary` from the WASM side entirely
2. The WASM `nam!` macro only exports the path and import call
3. The host parses the model and stores it natively
4. WASM calls the import for inference

### 5. Simplify the `nam!` macro

**`rust/conjuredsp-rs/src/lib.rs`** — Simplify the `nam!` macro. No more `NAM_DATA_BUF`, `NAM_MODEL`, `init_nam`, `get_nam_data_ptr`, `get_nam_active`. Just:

```rust
macro_rules! nam {
    ($path:expr) => {
        static NAM_PATH: &str = $path;
        static mut NAM_IN: [f32; MAX_FR] = [0.0; MAX_FR];
        static mut NAM_OUT: [f32; MAX_FR] = [0.0; MAX_FR];

        extern "C" {
            fn __conjuredsp_nam_process(
                input_ptr: *const f32, output_ptr: *mut f32,
                frames: i32, channel: i32,
            ) -> i32;
        }

        /// Process audio through the host-side NAM model.
        /// Returns true if model was active and processed.
        #[inline]
        unsafe fn nam_process(input: &[f32], output: &mut [f32], channel: usize) -> bool {
            __conjuredsp_nam_process(
                input.as_ptr(), output.as_mut_ptr(),
                input.len() as i32, channel as i32,
            ) == 1
        }

        #[no_mangle]
        pub extern "C" fn get_nam_path_ptr() -> i32 { NAM_PATH.as_ptr() as i32 }
        #[no_mangle]
        pub extern "C" fn get_nam_path_len() -> i32 { NAM_PATH.len() as i32 }
    };
}
```

User scripts change from:
```rust
if let Some(model) = NAM_MODEL.as_mut() {
    model.process_buffer(&NAM_IN[..n], &mut NAM_OUT[..n], c);
}
```
To:
```rust
nam_process(&NAM_IN[..n], &mut NAM_OUT[..n], c);
```

### 6. Update preset templates and docs

- **`preset_nam_rust.rs`**: Update to use `nam_process()` instead of `NAM_MODEL.as_mut()` + `process_buffer`
- **MCP docs** (`ConjureDSPExtensionAudioUnit+MCP.swift`): Update Rust NAM API reference
- **CLAUDE.md**: Update NAM architecture description

### 7. Host-side injection changes

**`rust/conjure_dsp/src/wasm_backend.rs`**:

- `inject_nam_model()` now parses the binary data using `conjuredsp_rs::NamModel::from_binary()` and stores the model in the store's `HostState` instead of writing to WASM memory
- Remove `get_nam_data_ptr_fn`, `init_nam_fn`, `get_nam_active_fn` fields (no longer needed)
- Keep `nam_path` field (still read from WASM exports)

**`rust/conjure_dsp/src/kernel.rs`**:
- No changes needed — `inject_nam()` still delegates to `WasmBackend::inject_nam_model()`

**Swift side** (`ConjureDSPExtensionAudioUnit.swift`):
- `injectNamModelIfNeeded()` still reads the `.nam` JSON file and serializes to binary
- Calls `dsp_kernel_inject_nam()` as before — the binary protocol is unchanged

## Files to modify

| File | Change |
|------|--------|
| `rust/conjure_dsp/Cargo.toml` | Add `conjuredsp-rs` as native dependency |
| `rust/conjuredsp-rs/Cargo.toml` | Ensure it compiles for both native and wasm32 |
| `rust/conjure_dsp/src/wasm_backend.rs` | Change store to `HostState`, register NAM import, update `inject_nam_model` |
| `rust/conjuredsp-rs/src/lib.rs` | Simplify `nam!` macro — remove WASM-side model, add import call |
| `rust/conjuredsp-rs/src/nam.rs` | No changes needed (host uses it natively) |
| `ConjureDSPExtension/Resources/preset_nam_rust.rs` | Update to use `nam_process()` API |
| `ConjureDSPExtension/Common/Audio Unit/ConjureDSPExtensionAudioUnit+MCP.swift` | Update Rust NAM docs |

## Verification

1. `cd rust && cargo test -- --test-threads=1` — Rust crate tests
2. `xcodebuild build` — full build
3. `xcodebuild test -only-testing:ConjureDSPTests` — unit tests
4. Manual: Load a Rust NAM preset via embedded Claude Code → should compile and produce audio
5. Manual: Compare benchmark timing between Python and Rust NAM presets — should be comparable
6. Manual: Verify the factory NAM preset (Python) still works unchanged
