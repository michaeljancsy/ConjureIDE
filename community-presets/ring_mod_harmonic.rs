// Ring Modulator — harmonic ring modulation.
//
// Multiplies the input by a carrier oscillator, creating sum and
// difference frequencies. Shape morphs sine to square.

use conjuredsp::*;
setup!();

params! {
    FREQUENCY = freq().min(20.0).max(5000.0).default(440.0),
    SHAPE = param(0.0, 1.0).default(0.0),
    MIX = mix().default(0.5),
}

static mut PHASE: f64 = 0.0;

#[no_mangle]
pub extern "C" fn process(
    input: *const f32,
    output: *mut f32,
    channels: i32,
    frame_count: i32,
    sample_rate: f32,
) {
    let ctx = ctx(input, output, channels, frame_count, sample_rate);
    let sr = sample_rate as f64;

    unsafe {
        let carrier_freq = ctx.param(FREQUENCY) as f64;
        let shape = ctx.param(SHAPE) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        let two_pi = 2.0 * core::f64::consts::PI;

        for i in 0..ctx.frames() {
            // Morphable carrier: sine -> square
            let sine = (two_pi * PHASE).sin();
            let carrier = if shape < 0.01 {
                sine
            } else {
                let square = if sine >= 0.0 { 1.0 } else { -1.0 };
                sine * (1.0 - shape) + square * shape
            };

            for ch in 0..ctx.channels() {
                let x = ctx.input(ch, i) as f64;
                let ring = x * carrier;
                ctx.set_output(ch, i, (x * (1.0 - wet_mix) + ring * wet_mix) as f32);
            }

            PHASE = (PHASE + carrier_freq / sr) % 1.0;
        }
    }
}
