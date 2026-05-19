// Parametric EQ — 4-band fully parametric equalizer.

use conjuredsp::*;
setup!();

params! {
    FREQ_1 = freq().min(50.0).max(500.0).default(100.0),
    GAIN_1 = db().min(-12.0).max(12.0).default(0.0),
    FREQ_2 = freq().min(200.0).max(2000.0).default(500.0),
    GAIN_2 = db().min(-12.0).max(12.0).default(0.0),
    FREQ_3 = freq().min(1000.0).max(8000.0).default(3000.0),
    GAIN_3 = db().min(-12.0).max(12.0).default(0.0),
    FREQ_4 = freq().min(4000.0).max(20000.0).default(10000.0),
    GAIN_4 = db().min(-12.0).max(12.0).default(0.0),
}

static mut BANDS: [[Biquad; 4]; MAX_CH] = [[Biquad::new(); 4]; MAX_CH];

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
        let freqs = [
            ctx.param(FREQ_1) as f64, ctx.param(FREQ_2) as f64,
            ctx.param(FREQ_3) as f64, ctx.param(FREQ_4) as f64,
        ];
        let gains = [
            ctx.param(GAIN_1) as f64, ctx.param(GAIN_2) as f64,
            ctx.param(GAIN_3) as f64, ctx.param(GAIN_4) as f64,
        ];

        for c in 0..ctx.channels() {
            for b in 0..4 {
                let coeffs = BiquadCoeffs::peak(freqs[b], 1.5, gains[b], sr);
                BANDS[c][b].set_coeffs(coeffs);
            }

            for i in 0..ctx.frames() {
                let mut x = ctx.input(c, i) as f64;
                for b in 0..4 {
                    x = BANDS[c][b].process_sample(x);
                }
                ctx.set_output(c, i, x as f32);
            }
        }
    }
}
