// Tilt EQ — single-knob tonal balance.

use conjuredsp::*;
setup!();

params! {
    TILT = param(-6.0, 6.0).unit("dB").default(0.0),
}

static mut LS: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut HS: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];

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
        let tilt_db = ctx.param(TILT) as f64;

        for c in 0..ctx.channels() {
            LS[c].set_coeffs(BiquadCoeffs::lowshelf(1000.0, 0.7, -tilt_db, sr));
            HS[c].set_coeffs(BiquadCoeffs::highshelf(1000.0, 0.7, tilt_db, sr));

            for i in 0..ctx.frames() {
                let mut x = ctx.input(c, i) as f64;
                x = LS[c].process_sample(x);
                x = HS[c].process_sample(x);
                ctx.set_output(c, i, x as f32);
            }
        }
    }
}
