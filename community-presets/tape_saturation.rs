// Tape Saturation — analog reel-to-reel tape warmth.
//
// Models the magnetic hysteresis of recording tape.

use conjuredsp::*;
setup!();

params! {
    DRIVE = param(0.0, 20.0).unit("dB").default(6.0),
    BIAS = param(0.0, 1.0).default(0.5),
    MIX = mix().default(0.8),
}

static mut FILTERS: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];

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
        let drive_db = ctx.param(DRIVE) as f64;
        let bias = ctx.param(BIAS) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        let drive_gain = db_to_gain(drive_db);
        let rolloff_freq = 4000.0 + bias * 12000.0;

        for c in 0..ctx.channels() {
            let coeffs = BiquadCoeffs::lowpass(rolloff_freq, 0.7, sr);
            FILTERS[c].set_coeffs(coeffs);

            for i in 0..ctx.frames() {
                let x = ctx.input(c, i) as f64 * drive_gain;

                let mut y = if x.abs() < 1.0 {
                    x - (x * x * x) / 3.0
                } else {
                    if x > 0.0 { 2.0 / 3.0 } else { -2.0 / 3.0 }
                };

                y += 0.05 * (bias - 0.5) * (x * x);
                y = FILTERS[c].process_sample(y);

                ctx.set_output(c, i, (ctx.input(c, i) as f64 * (1.0 - wet_mix) + y * wet_mix) as f32);
            }
        }
    }
}
