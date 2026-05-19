// Harmonic Exciter — Aphex Aural Exciter-inspired enhancer.

use conjuredsp::*;
setup!();

params! {
    FREQUENCY = freq().min(1000.0).max(10000.0).default(3000.0),
    HARMONICS = param(0.0, 1.0).default(0.5),
    MIX = mix().default(0.3),
}

static mut HP_FILTERS: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];

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
        let crossover = ctx.param(FREQUENCY) as f64;
        let harm_drive = 1.0 + ctx.param(HARMONICS) as f64 * 10.0;
        let wet_mix = ctx.param(MIX) as f64;

        for c in 0..ctx.channels() {
            let coeffs = BiquadCoeffs::highpass(crossover, 0.7, sr);
            HP_FILTERS[c].set_coeffs(coeffs);

            for i in 0..ctx.frames() {
                let x = ctx.input(c, i) as f64;
                let highs = HP_FILTERS[c].process_sample(x);
                let harmonics = (highs * harm_drive).tanh() - highs;
                ctx.set_output(c, i, (x + harmonics * wet_mix) as f32);
            }
        }
    }
}
