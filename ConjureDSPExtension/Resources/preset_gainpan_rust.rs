// Gain + Pan — volume control with stereo panning.
//
// Applies gain and constant-power panning to the signal.
//
// Params:
//   0 (Gain): Volume — -24 to +12 dB
//   1 (Pan):  Stereo position — 0.0 = hard left, 0.5 = center, 1.0 = hard right

use conjuredsp::*;
setup!();

params! {
    GAIN = param(-24.0, 12.0).unit("dB").default(0.0),
    PAN = param(0.0, 1.0).default(0.5),
}

#[no_mangle]
pub extern "C" fn process(
    input: *const f32,
    output: *mut f32,
    channels: i32,
    frame_count: i32,
    _sample_rate: f32,
) {
    let ctx = ctx(input, output, channels, frame_count, _sample_rate);
    let half_pi = core::f32::consts::PI * 0.5;

    let gain_db = ctx.param(GAIN);
    let pan = ctx.param(PAN);

    let gain = (10.0_f32).powf(gain_db / 20.0);

    if ctx.channels() == 1 {
        for i in 0..ctx.frames() {
            ctx.set_output(0, i, ctx.input(0, i) * gain);
        }
    } else {
        let left_gain = gain * (pan * half_pi).cos();
        let right_gain = gain * (pan * half_pi).sin();
        for i in 0..ctx.frames() {
            ctx.set_output(0, i, ctx.input(0, i) * left_gain);
            ctx.set_output(1, i, ctx.input(1, i) * right_gain);
        }
    }
}
