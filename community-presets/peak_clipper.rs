// Peak Clipper — mastering-grade hard/soft clipper.

use conjuredsp::*;
setup!();

params! {
    CEILING = db().min(-6.0).max(0.0).default(-1.0),
    INPUT = db().min(0.0).max(12.0).default(3.0),
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
        let ceiling = db_to_gain(ctx.param(CEILING) as f64);
        let input_gain = db_to_gain(ctx.param(INPUT) as f64);

        let tanh_1_5 = 1.5_f64.tanh();

        for c in 0..ctx.channels() {
            for i in 0..ctx.frames() {
                let x = ctx.input(c, i) as f64 * input_gain;
                let x_norm = x / ceiling;

                let y = if x_norm.abs() > 0.5 {
                    (x_norm * 1.5).tanh() / tanh_1_5
                } else {
                    x_norm
                };

                ctx.set_output(c, i, (y * ceiling) as f32);
            }
        }
    }
}
