// Mid/Side Processor — stereo field manipulation.
//
// Encode mode converts L/R to Mid/Side, allowing independent
// gain control of the center and sides of the stereo field.

use conjuredsp::*;
setup!();

params! {
    MODE = choice(&["Encode", "Decode"]),
    MID_GAIN = db(-12.0, 12.0).default(0.0),
    SIDE_GAIN = db(-12.0, 12.0).default(0.0),
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

    unsafe {
        let mode = ctx.param(MODE) as i32;
        let mid_g = db_to_gain(ctx.param(MID_GAIN) as f64);
        let side_g = db_to_gain(ctx.param(SIDE_GAIN) as f64);

        if ctx.channels() < 2 {
            // Mono: just pass through
            for i in 0..ctx.frames() {
                ctx.set_output(0, i, ctx.input(0, i));
            }
            return;
        }

        if mode == 0 {
            // Encode: L/R -> M/S
            for i in 0..ctx.frames() {
                let left = ctx.input(0, i) as f64;
                let right = ctx.input(1, i) as f64;

                let mid = (left + right) * 0.5 * mid_g;
                let side = (left - right) * 0.5 * side_g;

                ctx.set_output(0, i, mid as f32);
                ctx.set_output(1, i, side as f32);
            }
        } else {
            // Decode: M/S -> L/R
            for i in 0..ctx.frames() {
                let mid = ctx.input(0, i) as f64 * mid_g;
                let side = ctx.input(1, i) as f64 * side_g;

                ctx.set_output(0, i, (mid + side) as f32);
                ctx.set_output(1, i, (mid - side) as f32);
            }
        }
    }
}
