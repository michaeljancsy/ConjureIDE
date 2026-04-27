// Hard Clip — hard clipping distortion.
//
// Amplifies the signal by the drive amount, then clips any values
// exceeding +/-1.0. Produces a harsh, buzzy distortion with odd harmonics.
// Higher drive values push more of the signal into clipping.
//
// Params:
//   0 (Drive): Amplification factor — 1.0 to 20.0

use conjuredsp::*;
setup!();

params! {
    DRIVE = param(1.0, 20.0).default(5.0),
}

#[no_mangle]
pub extern "C" fn process(
    input: *const f32,
    output: *mut f32,
    channel_count: i32,
    frame_count: i32,
    _sample_rate: f32,
) {
    let ctx = ctx(input, output, channel_count, frame_count, _sample_rate);
    let drive = ctx.param(DRIVE);

    for c in 0..ctx.channels() {
        for i in 0..ctx.frames() {
            let driven = drive * ctx.input(c, i);
            let clipped = if driven > 1.0 {
                1.0
            } else if driven < -1.0 {
                -1.0
            } else {
                driven
            };
            ctx.set_output(c, i, clipped);
        }
    }
}
