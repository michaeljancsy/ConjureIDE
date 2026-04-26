// DC Blocker — removes DC offset from the signal.
//
// Implements a first-order high-pass filter:
//     y[n] = x[n] - x[n-1] + R * y[n-1]
// where R controls the cutoff frequency (closer to 1.0 = lower cutoff).
// The cutoff parameter sets the -3dB frequency in Hz; R is computed
// from the sample rate using the exact exponential formula.
//
// Params:
//   0 (Cutoff): High-pass cutoff — 4 to 70 Hz

use conjuredsp::*;
setup!();

params! {
    CUTOFF = freq().min(4.0).max(70.0).default(4.0),
}

// Persistent state per channel: [prev_x, prev_y]
// Use f64 to match Python's float64 precision — f32 accumulation
// in the feedback loop (R * prev_y) causes audible rounding drift.
static mut PREV_X: [f64; MAX_CH] = [0.0; MAX_CH];
static mut PREV_Y: [f64; MAX_CH] = [0.0; MAX_CH];

#[no_mangle]
pub extern "C" fn process(
    input: *const f32,
    output: *mut f32,
    channel_count: i32,
    frame_count: i32,
    sample_rate: f32,
) {
    let ctx = ctx(input, output, channel_count, frame_count, sample_rate);

    let cutoff_hz = ctx.param(CUTOFF) as f64;
    let r = (-2.0 * core::f64::consts::PI * cutoff_hz / (sample_rate as f64)).exp();

    unsafe {
        for c in 0..ctx.channels() {
            let mut px = PREV_X[c];
            let mut py = PREV_Y[c];

            for i in 0..ctx.frames() {
                let x = ctx.input(c, i) as f64;
                py = x - px + r * py;
                px = x;
                ctx.set_output(c, i, py as f32);
            }

            PREV_X[c] = px;
            PREV_Y[c] = py;
        }
    }
}
