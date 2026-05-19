// Rectifier Distortion — waveform rectification effect.

use conjuredsp::*;
setup!();

params! {
    MODE = choice(&["Full", "Half"]),
    DRIVE = param(1.0, 10.0).unit("x").default(3.0),
    TONE = param(0.0, 1.0).default(0.5),
    MIX = mix().default(0.5),
}

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
        let mode = ctx.param(MODE) as i32;
        let drive = ctx.param(DRIVE) as f64;
        let tone = ctx.param(TONE) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        let lp_freq = 1000.0 + tone * 15000.0;

        for c in 0..ctx.channels() {
            let coeffs = BiquadCoeffs::lowpass(lp_freq, 0.7, sr);
            LP[c].set_coeffs(coeffs);

            for i in 0..ctx.frames() {
                let x = ctx.input(c, i) as f64 * drive;

                let y = if mode == 0 {
                    x.abs()
                } else {
                    if x > 0.0 { x } else { 0.0 }
                };

                let y = y.tanh();
                let y = LP[c].process_sample(y);

                ctx.set_output(c, i, (ctx.input(c, i) as f64 * (1.0 - wet_mix) + y * wet_mix) as f32);
            }
        }
    }
}
