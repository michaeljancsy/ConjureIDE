// Harmonic Tremolo — Fender Brownface-style frequency-split tremolo.
//
// Splits the signal into low and high bands and modulates them with
// opposite LFO phases. When lows get louder, highs get quieter and
// vice versa. The signature sound of early 60s Fender amps.

use conjuredsp::*;
setup!();

params! {
    RATE = param(1.0, 12.0).unit("Hz").default(5.0),
    DEPTH = param(0.0, 1.0).default(0.7),
    CROSSOVER = param(500.0, 2000.0).unit("Hz").default(800.0),
}

static mut PHASE: f64 = 0.0;
static mut LP: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut HP: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];

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
        let rate = ctx.param(RATE) as f64;
        let depth = ctx.param(DEPTH) as f64;
        let xover = ctx.param(CROSSOVER) as f64;

        let two_pi = 2.0 * core::f64::consts::PI;

        for c in 0..ctx.channels() {
            LP[c].set_coeffs(BiquadCoeffs::lowpass(xover, 0.7, sr));
            HP[c].set_coeffs(BiquadCoeffs::highpass(xover, 0.7, sr));

            for i in 0..ctx.frames() {
                let x = ctx.input(c, i) as f64;
                let low = LP[c].process(x);
                let high = HP[c].process(x);

                // Opposite-phase modulation
                let modulation = (two_pi * PHASE).sin();
                let low_gain = 1.0 - depth * 0.5 * (1.0 + modulation);
                let high_gain = 1.0 - depth * 0.5 * (1.0 - modulation);

                ctx.set_output(c, i, (low * low_gain + high * high_gain) as f32);

                if c == 0 {
                    PHASE = (PHASE + rate / sr) % 1.0;
                }
            }
        }
    }
}
