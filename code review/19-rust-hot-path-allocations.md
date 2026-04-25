An AI has found the following issue. Please review and assess whether action is needed.

# Rust: Vec::new / Vec::with_capacity called on the audio render path

## Context
ConjureDSP's audio render path runs through `rust/conjure_dsp/src/kernel.rs`, which dispatches to `python_backend` or `wasm_backend`. The cardinal rule: no allocation, locking, or syscalls in this path — anything that can stall pushes you toward xruns.

## Issue
The reviewer flagged that `kernel.rs` (around lines 1119–1126) calls `Vec::with_capacity()` / `Vec::new()` to convert mutable output pointers into const pointers (or for some scratch purpose) on every render callback. This is a per-callback heap allocation. At 256-frame buffers and 48kHz, that's ~187 allocations/second per active plugin instance.

## Location
- `rust/conjure_dsp/src/kernel.rs` — process path around lines 1119–1126
- Worth a wider sweep: `grep -n "Vec::\|Box::new\|String::new\|format!" rust/conjure_dsp/src/kernel.rs rust/conjure_dsp/src/python_backend.rs rust/conjure_dsp/src/wasm_backend.rs`

## Why it matters
- macOS uses `nano_malloc` for small allocations, which is fast in the common case but takes a per-zone lock. Under contention (many plugins, complex projects), this lock becomes the bottleneck and produces audible glitches.
- The whole point of the kernel's ring-buffer / scratch-buffer architecture is to allocate at `allocate_render_resources` time, not per-callback. A per-callback Vec defeats it.
- Profiling tools (Instruments → Time Profiler with "Mark allocations" or `MallocStackLogging`) will surface this as a hot spot.

## What to verify
- Read `kernel.rs` end to end, focusing on the function called from `dsp_kernel_process` / `internalRenderBlock`.
- For every collection operation in that path, identify whether it's reusing a pre-allocated buffer or allocating fresh.
- Check `python_backend.rs` and `wasm_backend.rs` for the same patterns (PyDict construction, wasmtime call argument boxing).

## Suggested approach
- Move all per-render scratch buffers to fields on `DSPKernel`, allocated in `allocate_render_resources(max_frames, max_channels)`.
- Pre-allocate output-pointer arrays as `[*const f32; MAX_CH]` (stack-allocated with a max channel constant) instead of Vec.
- For Python: keep the PyList/PyDict from initialization and reuse it; only update the values, don't recreate the container.
- Add a debug-only allocation tracker for the render path (e.g., `tracking-allocator` crate gated behind a cfg) to catch regressions.
