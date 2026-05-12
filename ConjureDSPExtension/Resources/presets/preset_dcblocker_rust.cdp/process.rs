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
params! {
    CUTOFF = freq().min(4.0).max(70.0).default(4.0),
}

// Persistent state per channel: [prev_x, prev_y]. f64 to match
// Python's float64 precision — f32 accumulation in the feedback loop
// (R * prev_y) causes audible rounding drift.
persist_buf!(PREV_X: [f64; MAX_CH] = [0.0; MAX_CH]);
persist_buf!(PREV_Y: [f64; MAX_CH] = [0.0; MAX_CH]);

process! { ctx =>
    let cutoff_hz = ctx.param(CUTOFF) as f64;
    let r = (-2.0 * core::f64::consts::PI * cutoff_hz / (ctx.sample_rate() as f64)).exp();

    PREV_X.with_mut(|prev_x| {
        PREV_Y.with_mut(|prev_y| {
            for c in 0..ctx.channels() {
                let mut px = prev_x[c];
                let mut py = prev_y[c];

                for i in 0..ctx.frames() {
                    let x = ctx.input(c, i) as f64;
                    py = x - px + r * py;
                    px = x;
                    ctx.set_output(c, i, py as f32);
                }

                prev_x[c] = px;
                prev_y[c] = py;
            }
        });
    });
}
