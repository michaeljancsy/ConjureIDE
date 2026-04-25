An AI has found the following issue. Please review and assess whether action is needed.

# Rust: thread-local C-string returned across FFI is a use-after-free hazard

## Context
ConjureDSP's Rust DSP kernel (`rust/conjure_dsp/`) exposes a C FFI consumed by Swift. Two functions return `*const c_char` pointing to thread-local storage owned by the kernel: `dsp_kernel_nam_path()` and `dsp_kernel_last_error()`.

## Issue
The reviewer flagged that the returned pointer is valid only until the next call to the same function on the same thread. If the Swift side calls one of these and stores the pointer for later use (caching for a UI label, passing to a logger that defers, etc.), the next call invalidates it — the new call rewrites the underlying buffer, so the cached pointer now points at unrelated bytes (or freed memory if the thread-local was reallocated).

## Location
- `rust/conjure_dsp/src/lib.rs` — `dsp_kernel_nam_path()` (~line 244) and `dsp_kernel_last_error()` (~line 309)
- Swift call sites: search for `dsp_kernel_nam_path` and `dsp_kernel_last_error` across `ConjureDSPExtension/`

## Why it matters
- Latent UAF / memory-corruption bug. Today it may not bite because Swift call sites happen to immediately copy into a `String`. A future refactor that defers the read (e.g., `let p = dsp_kernel_last_error(); ... call something else ...; String(cString: p!)`) silently corrupts.
- Particularly bad for `last_error` — error reporting is the one place you really don't want a memory bug.
- The pattern violates the "FFI ownership must be explicit" rule that human reviewers always flag.

## What to verify
- Read both FFI functions and the thread-local they reference.
- Find every Swift caller (`grep -rn "dsp_kernel_nam_path\|dsp_kernel_last_error"`) and check that each one copies into a Swift `String` synchronously and never stores the raw pointer.
- Check whether either function is called from multiple threads — if a worker thread caches a pointer and the audio thread calls the same function, that's also UAF.

## Suggested approach
- Replace with caller-allocated buffer pattern: `dsp_kernel_last_error(buf: *mut c_char, len: usize) -> usize` returns bytes written. Swift allocates a stack buffer (`var buf = [CChar](repeating: 0, count: 512)`) and reads into it.
- Or: return a heap-allocated string via `CString::into_raw` and add a corresponding `dsp_kernel_string_free(ptr: *mut c_char)` that Swift must call. This is more flexible (no length limit) but requires discipline.
- Either way, document the ownership contract in the header.
