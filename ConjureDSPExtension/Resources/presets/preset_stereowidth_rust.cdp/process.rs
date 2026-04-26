// Stereo Width — mid/side stereo width control.
//
// Encodes the stereo signal into mid (L+R) and side (L-R) components,
// scales the side component by the width factor, then decodes back to
// L/R. At WIDTH=0 the output is mono, at WIDTH=1 the signal is
// unchanged, and above 1.0 the stereo image is exaggerated.
// For mono input, the signal passes through unchanged.
//
// Params:
//   0 (Width): Stereo width — 0.0 to 2.0

use conjuredsp::*;
setup!();

params! {
    WIDTH = param(0.0, 2.0).default(1.0),
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

    unsafe {
        let width = ctx.param(WIDTH);

        if ctx.channels() < 2 {
            // Mono: passthrough
            for i in 0..ctx.frames() {
                ctx.set_output(0, i, ctx.input(0, i));
            }
            return;
        }

        for i in 0..ctx.frames() {
            let left = ctx.input(0, i);
            let right = ctx.input(1, i);

            // Encode to mid/side
            let mid = (left + right) * 0.5;
            let side = (left - right) * 0.5;

            // Scale side component
            let side_scaled = side * width;

            // Decode back to L/R
            ctx.set_output(0, i, mid + side_scaled);
            ctx.set_output(1, i, mid - side_scaled);
        }
    }
}
