// Telephone — lo-fi telephone / radio bandpass effect.

use conjuredsp::*;
setup!();

params! {
    QUALITY = param(0.0, 1.0).default(0.5),
    NOISE = param(0.0, 0.05).default(0.01),
    MIX = mix().default(1.0),
}

static mut HP_F: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut LP_F: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut MID_F: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut RNG_STATE: u32 = 12345;

fn rng() -> f64 {
    unsafe {
        RNG_STATE = RNG_STATE.wrapping_mul(1664525).wrapping_add(1013904223);
        RNG_STATE as f64 / 4294967296.0
    }
}

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
        let quality = ctx.param(QUALITY) as f64;
        let noise_level = ctx.param(NOISE) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        let hp_freq = 300.0 + (1.0 - quality) * 700.0;
        let lp_freq = 3400.0 - (1.0 - quality) * 1800.0;

        for c in 0..ctx.channels() {
            HP_F[c].set_coeffs(BiquadCoeffs::highpass(hp_freq, 1.0, sr));
            LP_F[c].set_coeffs(BiquadCoeffs::lowpass(lp_freq, 1.0, sr));
            MID_F[c].set_coeffs(BiquadCoeffs::peak(1500.0, 1.0, 6.0, sr));

            for i in 0..ctx.frames() {
                let x = ctx.input(c, i) as f64;

                let mut y = HP_F[c].process_sample(x);
                y = LP_F[c].process_sample(y);
                y = MID_F[c].process_sample(y);

                y = (y * 2.0).tanh() * 0.6;

                y += (rng() - 0.5) * noise_level;

                ctx.set_output(c, i, (ctx.input(c, i) as f64 * (1.0 - wet_mix) + y * wet_mix) as f32);
            }
        }
    }
}
