An AI has found the following issue. Please review and assess whether action is needed.

# Rust: demo_fade_step computed as 1000 / (DEMO_FADE_MS * sample_rate) without validation

## Context
ConjureDSP has a demo mode: unlicensed users get 60 seconds of processing before output is silenced. The transition uses a fade-in/fade-out envelope. The fade step per sample is computed from the configured fade duration in milliseconds and the current sample rate.

## Issue
The reviewer flagged (around lines 346–356 of `kernel.rs`) that the computation `(1000.0 / (DEMO_FADE_MS * sample_rate))` produces NaN or Inf when `sample_rate` is 0, negative, or NaN. There's no validation. The resulting `demo_fade_step` then propagates NaN into the audio buffer via the fade-gain multiplication.

## Location
- `rust/conjure_dsp/src/kernel.rs` — `initialize()`, demo fade computation ~lines 346–356

## Why it matters
- Misbehaving DAWs (or a brief moment during sample-rate change) can deliver `sample_rate = 0` to `allocate_render_resources` / `initialize`. Some hosts pass garbage briefly during reconfiguration.
- Once NaN enters the audio path, it's contagious — it propagates through every subsequent multiply and persists indefinitely. Users hear silence with occasional pops as DAC clamps NaN.
- This same defensive-validation issue likely exists elsewhere in the kernel anywhere `sample_rate` is divided by.

## What to verify
- Read `kernel.rs` `initialize()` end to end.
- Search the file for `sample_rate` usage and identify every division. Each is a NaN/Inf risk point.
- Check whether `sample_rate` is validated at the FFI boundary in `lib.rs` — if it is, this is moot; if not, the entire kernel is exposed.

## Suggested approach
- Add a guard at the FFI entry point (`dsp_kernel_initialize` or wherever sample rate enters): reject sample rates outside `[8000.0, 384_000.0]` and return an error to Swift.
- Inside `kernel.rs`, defensively clamp `sample_rate` to a minimum (e.g., `sample_rate.max(1.0)`) before any division. Cheap insurance.
- Add a debug-time check that `demo_fade_step.is_finite()` after computation — fail loudly if not.
- Audit the rest of `kernel.rs`, `python_backend.rs`, and `wasm_backend.rs` for similar patterns (`/ sample_rate`, `/ frame_count`, `/ channel_count`).
