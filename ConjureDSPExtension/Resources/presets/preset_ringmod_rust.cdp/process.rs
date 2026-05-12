// Ring Modulator — multiplies the signal by a sine-wave carrier.
//
// Multiplies the input signal by a sine wave at the carrier frequency.
// This creates sum and difference frequencies, producing metallic,
// bell-like, or robotic timbres. Unlike tremolo (which modulates
// amplitude around a bias), ring modulation has no DC offset, so the
// carrier frequency components are always present in the output.
//
// Params:
//   0 (Frequency): Carrier frequency — 20 to 20000 Hz (log)

use conjuredsp::*;
params! {
    FREQUENCY = freq().default(440.0),
}

// Persistent phase across callbacks. f64 to match Python's float64
// precision in the phase accumulator.
persist!(PHASE: f64 = 0.0);

process! { ctx =>
    let sr = ctx.sample_rate() as f64;
    let two_pi = 2.0 * core::f64::consts::PI;

    let carrier_hz = ctx.param(FREQUENCY) as f64;
    let phase_start = PHASE.get();

    // Match Python's vectorized pattern: compute carrier from absolute
    // time within the chunk rather than accumulating phase per-sample.
    // This avoids floating-point drift from per-sample phase addition.
    for i in 0..ctx.frames() {
        let t = (i as f64) / sr;
        let carrier = (two_pi * carrier_hz * t + phase_start).sin();
        for c in 0..ctx.channels() {
            ctx.set_output(c, i, (ctx.input(c, i) as f64 * carrier) as f32);
        }
    }

    PHASE.set((phase_start + two_pi * carrier_hz * (ctx.frames() as f64) / sr) % two_pi);
}
