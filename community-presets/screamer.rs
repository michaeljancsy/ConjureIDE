// Screamer — Tube Screamer-inspired mid-boosted overdrive.

use conjuredsp::*;
setup!();

params! {
    DRIVE = param(1.0, 30.0).unit("x").default(8.0),
    TONE = param(0.0, 1.0).default(0.6),
    LEVEL = db().min(-20.0).max(6.0).default(0.0),
}

static mut HP: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut MID_BOOST: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut LP: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];

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
        let drive = ctx.param(DRIVE) as f64;
        let tone = ctx.param(TONE) as f64;
        let level = db_to_gain(ctx.param(LEVEL) as f64);

        for c in 0..ctx.channels() {
            HP[c].set_coeffs(BiquadCoeffs::highpass(200.0, 0.7, sr));
            MID_BOOST[c].set_coeffs(BiquadCoeffs::peak(800.0, 1.5, 6.0, sr));

            let lp_freq = 2000.0 + tone * 8000.0;
            LP[c].set_coeffs(BiquadCoeffs::lowpass(lp_freq, 0.7, sr));

            for i in 0..ctx.frames() {
                let mut x = ctx.input(c, i) as f64;
                x = HP[c].process_sample(x);
                x = MID_BOOST[c].process_sample(x);
                x *= drive;

                let y = x.tanh();
                let y = LP[c].process_sample(y);

                ctx.set_output(c, i, (y * level) as f32);
            }
        }
    }
}
