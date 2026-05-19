// Transparent Overdrive — Klon Centaur-inspired asymmetric clipping.

use conjuredsp::*;
setup!();

params! {
    GAIN = db().min(0.0).max(30.0).default(12.0),
    TONE = param(0.0, 1.0).default(0.6),
    MIX = mix().default(1.0),
}

static mut HP_FILTERS: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut LP_FILTERS: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];

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
        let gain = db_to_gain(ctx.param(GAIN) as f64);
        let tone = ctx.param(TONE) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        for c in 0..ctx.channels() {
            let hp_coeffs = BiquadCoeffs::highpass(120.0, 0.7, sr);
            HP_FILTERS[c].set_coeffs(hp_coeffs);

            let lp_freq = 2000.0 + tone * 10000.0;
            let lp_coeffs = BiquadCoeffs::lowpass(lp_freq, 0.7, sr);
            LP_FILTERS[c].set_coeffs(lp_coeffs);

            for i in 0..ctx.frames() {
                let mut x = HP_FILTERS[c].process_sample(ctx.input(c, i) as f64);
                x *= gain;

                let y = if x >= 0.0 {
                    (x * 0.8).tanh()
                } else {
                    (x * 1.5).tanh() * 0.7
                };

                let filtered = LP_FILTERS[c].process_sample(y);

                ctx.set_output(c, i, (ctx.input(c, i) as f64 * (1.0 - wet_mix) + filtered * wet_mix) as f32);
            }
        }
    }
}
