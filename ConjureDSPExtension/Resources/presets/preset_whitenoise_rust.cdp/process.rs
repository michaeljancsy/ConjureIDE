// White Noise Generator — generates uniform white noise.
//
// Ignores the input signal and fills the output with pseudo-random
// noise using a linear congruential generator. The LCG state persists
// across callbacks for a continuous noise stream. Both Python and Rust
// implementations use the same LCG constants for identical output.
//
// Params:
//   0 (Level): Noise amplitude — 0.0 to 1.0

use conjuredsp::*;
setup!();

params! {
    LEVEL = param(0.0, 1.0).default(0.5),
}

// LCG random state
static mut RNG_STATE: u32 = 12345;

fn next_f32() -> f32 {
    unsafe {
        RNG_STATE = RNG_STATE.wrapping_mul(1664525).wrapping_add(1013904223);
        (RNG_STATE as f32) / 4294967296.0 * 2.0 - 1.0
    }
}

#[no_mangle]
pub extern "C" fn process(
    _input: *const f32,
    output: *mut f32,
    channels: i32,
    frame_count: i32,
    _sample_rate: f32,
) {
    let ctx = ctx(_input, output, channels, frame_count, _sample_rate);

    let amplitude = ctx.param(LEVEL);

    for i in 0..ctx.frames() {
        let sample = next_f32() * amplitude;
        for c in 0..ctx.channels() {
            ctx.set_output(c, i, sample);
        }
    }
}
