// ConjureDSP DSP — Rust Template
//
// This script is compiled to WebAssembly and runs in the audio render callback.
// The `process` function is called once per audio buffer.
//
// Quick start:
//   - setup!() declares all required buffers and WASM exports
//   - params! {} declares parameters with rich metadata
//   - ctx() provides safe access to input/output buffers and parameters
//
// Safety: avoid allocations, I/O, or panics in process().

use conjuredsp::*;
setup!();

// Declare parameters — the host shows real ranges, units, and sliders.
// Builders: freq(), db(), time_ms(), mix(), pct(), toggle(), ratio(), param(min, max)
params! {
    GAIN = db().min(-24.0).max(12.0).default(0.0),
}

#[no_mangle]
pub extern "C" fn process(
    input: *const f32,
    output: *mut f32,
    channels: i32,
    frame_count: i32,
    sample_rate: f32,
) {
    let ctx = ctx(input, output, channels, frame_count, sample_rate);
    let gain = db_to_gain(ctx.param(GAIN) as f64) as f32;

    for c in 0..ctx.channels() {
        for i in 0..ctx.frames() {
            ctx.set_output(c, i, ctx.input(c, i) * gain);
        }
    }
}
