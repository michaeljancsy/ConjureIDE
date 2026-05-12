// ConjureDSP DSP — Rust Template
//
// This script is compiled to WebAssembly and runs in the audio render callback.
// `process! { ctx => ... }` is the entry point — it generates the WASM exports
// and runs the body once per audio buffer.
//
// Quick start:
//   - process! { ctx => ... } — entry point; binds `ctx: Context` for the body
//   - params! { ... }         — parameter metadata, generates index constants
//   - persist!(NAME: T = v)   — scalar / Copy state across blocks (.get/.set)
//   - persist_buf!(NAME: T)   — large-array state with in-place .with_mut(|b|)
//
// Safety: avoid allocations, I/O, or panics in the process body.

use conjuredsp::*;

// Declare parameters — the host shows real ranges, units, and sliders.
// Builders: freq(), db(), time_ms(), mix(), pct(), toggle(), ratio(), param(min, max)
params! {
    GAIN = db().min(-24.0).max(12.0).default(0.0),
}

process! { ctx =>
    let gain = db_to_gain(ctx.param(GAIN) as f64) as f32;

    for c in 0..ctx.channels() {
        for i in 0..ctx.frames() {
            ctx.set_output(c, i, ctx.input(c, i) * gain);
        }
    }
}
