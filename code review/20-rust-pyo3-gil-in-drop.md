An AI has found the following issue. Please review and assess whether action is needed.

# Rust: Python::with_gil() called in Drop / error paths

## Context
`rust/conjure_dsp/src/python_backend.rs` embeds free-threaded Python 3.14 via pyo3. Even with the no-GIL build, pyo3 0.27's API still requires `Python::with_gil(...)` for safety (the free-threaded build relaxes some constraints but the API contract is unchanged for now).

## Issue
The reviewer flagged (around lines 177–188) that `Python::with_gil()` is called unconditionally in error-handling paths and in `Drop` impls. Calling `with_gil` from `Drop` is dangerous because:
1. If the Python interpreter has been finalized (e.g., during process shutdown), `with_gil` aborts.
2. If `Drop` runs from an unexpected thread (e.g., a destructor running on the audio thread or a worker), GIL acquisition is at minimum slow and at worst a deadlock if some other code holds it.
3. Free-threaded Python doesn't fully eliminate these issues at the pyo3 API level in 0.27.

## Location
- `rust/conjure_dsp/src/python_backend.rs` — Drop impls and error paths, ~lines 177–188
- Search wider: `grep -n "with_gil\|Drop for\|impl Drop" rust/conjure_dsp/src/python_backend.rs`

## Why it matters
- Plugin teardown can hit this: when a host removes the AU, Swift drops the Rust kernel, which drops the Python state. If the interpreter is already shutting down (process exit), the abort is the host's only signal.
- Audio-thread `Drop`: if any `Py<...>` holding object is dropped from the audio thread (e.g., a swap during preset change), GIL acquisition there violates the audio-thread real-time contract.

## What to verify
- Read `python_backend.rs` end to end. Inventory every `with_gil` call and every type with a `Drop` impl that holds Python objects.
- Check what thread drops happen on — trace from `dsp_kernel_destroy` and from preset-swap paths.
- Confirm whether the process-shutdown path actually finalizes Python (it shouldn't, in a plugin context — but verify).

## Suggested approach
- For Drop impls that hold Python objects, prefer `Py::drop_ref` patterns or schedule the drop onto a dedicated Python thread via a queue. Don't call `with_gil` directly in Drop.
- Wrap the call site in a `pyo3::PyResult` and handle the "interpreter finalized" case explicitly.
- For preset-swap on the audio thread: ensure the swap itself only swaps an `AtomicPtr` or similar, and the previous Python state is dropped on a Tokio/std task off-thread.
- Consider whether free-threaded Python actually buys you anything here if the contract still requires `with_gil` everywhere; pyo3 has docs on the FT migration story worth reviewing.
