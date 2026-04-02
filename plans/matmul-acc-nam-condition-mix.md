# Plan: Replace NAM condition mix nested loop with Accelerate-backed `matmul_acc`

## Context

PR #151 (branch `claude/jovial-leakey`) fixes NAM bugs. There's a triple-nested for loop in `nam.rs:637-646` performing a condition mix operation that should use Accelerate like the other math in this file. The loop computes `conv_out[mid_ch x l_out] += mix_w[mid_ch x condition_size] @ condition[condition_size x cond_len]`, where condition data is strided in memory.

## Approach: New `matmul_acc` (matrix multiply-accumulate) host import

Add `accel::matmul_acc(a, b, c, m, k, n)` that computes `C += A @ B`, backed by `cblas_sgemm` with `alpha=1, beta=1`. Gather the strided condition data to contiguous scratch first, then call matmul_acc.

## Files to modify

### 1. `rust/conjuredsp-rs/src/accel.rs` — new `matmul_acc` function
- Add `host_matmul_acc` to the wasm32 extern block (same signature as `host_matmul`)
- Add `pub fn matmul_acc(a, b, c, m, k, n)` — same pattern as `matmul()` but:
  - WASM: calls `host_matmul_acc`
  - Native fallback: `c[i*n+j] += sum` (accumulate, not assign)
- Add tests: verify accumulation with pre-filled C matrix

### 2. `rust/conjure_dsp/src/wasm_backend.rs` — host-side implementation
- Add `cblas_sgemm` to the `extern "C"` block (it's in Accelerate/vecLib, same linkage)
- Register `host_matmul_acc` in `add_conjuredsp_imports()` — same bounds-checking pattern as `host_matmul`, but calls `cblas_sgemm(CblasRowMajor=101, CblasNoTrans=111, CblasNoTrans=111, m, n, k, alpha=1.0, A, lda=k, B, ldb=n, beta=1.0, C, ldc=n)`

### 3. `rust/conjuredsp-rs/src/nam.rs` — replace the loop
Replace lines 633-647 with:
1. **Gather** strided condition rows into contiguous scratch: for each `c in 0..condition_size`, copy `cond_len` floats from `self.work[c * full_len + (full_len - cond_len)]` to `scratch_off + c * cond_len` (scratch region is free after conv1d completes)
2. **matmul_acc**: when `cond_len == l_out` (common case), call `accel::matmul_acc` directly with C = conv_out region — output layout matches perfectly
3. **Fallback** for `cond_len < l_out` (rare startup frames): `accel::matmul` into scratch area past the gathered data, then row-by-row `vec_add` into conv_out (since output stride `l_out` != result stride `cond_len`)

## Verification
- Run Rust unit tests: `cd rust && DYLD_LIBRARY_PATH="$(pwd)/python-dist/lib" PYO3_PYTHON="$(pwd)/python-dist/bin/python3" cargo test -- --test-threads=1`
- Run Swift unit tests: `xcodebuild -project ConjureDSP.xcodeproj -scheme ConjureDSP test -only-testing:ConjureDSPTests`
- The existing `NamIdentityTests` validate that NAM processing produces correct output
