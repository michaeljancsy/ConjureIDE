An AI has found the following issue. Please review and assess whether action is needed.

# Rust: WASM-returned (ptr, len) decoded as UTF-8 without bounds clamping

## Context
`rust/conjure_dsp/src/wasm_backend.rs` reads strings out of guest WASM memory. The guest exports a function that returns a pointer and a length (e.g., `get_param_metadata_ptr` + `get_param_metadata_len`); the host reads `len` bytes starting at `ptr` and decodes them as UTF-8.

## Issue
The reviewer flagged (around lines 240–254) that the slice construction does not clamp the `len` value against the actual size of the WASM memory after `ptr`. If a malformed or malicious WASM module returns a `len` larger than `memory.len() - ptr`, slicing panics. That panic happens on the audio thread's hot path during the per-render WASM call surface (or at script-load time, depending on the function).

## Location
- `rust/conjure_dsp/src/wasm_backend.rs` — string-read paths around lines 240–254 and any similar `(ptr, len)` extraction (look for `data.get`, `from_utf8`, `from_raw_parts`)

## Why it matters
- **Crash on the audio thread**: a panic in a `wasmtime` host function unwinds into wasmtime, which surfaces as a trap; depending on how the kernel handles it, the result is either passthrough fallback (best case) or a propagated abort.
- **Untrusted input**: WASM modules are user-authored or, more dangerously, may someday be downloaded (community presets). Treating WASM as adversarial is the right posture.
- The `from_utf8` failure is independently handled, but `from_raw_parts` / direct slicing with bad length is a panic before UTF-8 even runs.

## What to verify
- Read `wasm_backend.rs` end to end. Find every place that reads a `(ptr, len)` from the guest.
- For each, confirm whether it bounds-checks against the current memory size.
- Check whether wasmtime's `Memory::data` is being used directly or via a safer accessor.

## Suggested approach
- Wrap reads in a helper:
  ```rust
  fn read_bytes(memory: &[u8], ptr: u32, len: u32) -> Option<&[u8]> {
      let start = ptr as usize;
      let end = start.checked_add(len as usize)?;
      memory.get(start..end)
  }
  ```
  Return `Option` and handle `None` by failing the load with a clear error.
- Apply uniformly to every guest-returned pointer/length pair, including parameter metadata, latency, and any future surface.
- Consider rejecting any WASM module whose declared metadata length exceeds a sanity cap (e.g., 64KB).
