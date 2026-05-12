// Low-Pass Filter — simple 1-pole IIR low-pass.
//
// Implements y[n] = (1 - a) * x[n] + a * y[n-1].
// Rolls off at 6 dB/octave above the cutoff frequency.
//
// Params:
//   0 (Cutoff): Cutoff frequency — 20 to 20000 Hz (log curve)

use conjuredsp::*;
params! {
    CUTOFF = freq(),
}

// Persistent state: previous output per channel. f64 to match
// Python's float64 precision in the feedback loop.
persist_buf!(PREV_OUT: [f64; MAX_CH] = [0.0; MAX_CH]);

process! { ctx =>
    let sr = ctx.sample_rate() as f64;
    let two_pi = 2.0 * core::f64::consts::PI;

    let cutoff_hz = ctx.param(CUTOFF) as f64;
    let a = (-two_pi * cutoff_hz / sr).exp();
    let b = 1.0 - a;

    PREV_OUT.with_mut(|prev_out| {
        for c in 0..ctx.channels() {
            let mut y = prev_out[c];
            for i in 0..ctx.frames() {
                y = b * ctx.input(c, i) as f64 + a * y;
                ctx.set_output(c, i, y as f32);
            }
            prev_out[c] = y;
        }
    });
}
