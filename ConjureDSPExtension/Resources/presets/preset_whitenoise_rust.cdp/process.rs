// White Noise Generator — generates uniform white noise.
//
// Ignores the input signal and fills the output with pseudo-random
// noise using a linear congruential generator. The LCG state persists
// across callbacks for a continuous noise stream. Both Python and Rust
// implementations use the same LCG constants for identical output.
//
// Controls:
//   0 (Level): Noise amplitude — 0.0 to 1.0

use conjuredsp::*;

params! {
    LEVEL = param(0.0, 1.0).default(0.5),
}

// LCG random state. Scalar Copy — persist! is enough; .replace() returns the
// old value while storing the new, mirroring `RNG_STATE = RNG_STATE * a + c`.
persist!(RNG_STATE: u32 = 12345);

fn next_f32() -> f32 {
    let next = RNG_STATE.get().wrapping_mul(1664525).wrapping_add(1013904223);
    RNG_STATE.set(next);
    (next as f32) / 4294967296.0 * 2.0 - 1.0
}

process! { ctx =>
    let amplitude = ctx.param(LEVEL);

    for i in 0..ctx.frames() {
        let sample = next_f32() * amplitude;
        for c in 0..ctx.channels() {
            ctx.set_output(c, i, sample);
        }
    }
}
