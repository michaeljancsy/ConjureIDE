// Expander / Gate — downward expansion for noise reduction.

use conjuredsp::*;
setup!();

params! {
    THRESHOLD = db().min(-60.0).max(-10.0).default(-40.0),
    RATIO = param(2.0, 20.0).unit(":1").default(8.0),
    ATTACK = time_ms().min(0.1).max(10.0).default(0.5),
    RELEASE = time_ms().min(10.0).max(1000.0).default(100.0),
    RANGE = db().min(-80.0).max(0.0).default(-40.0),
}

static mut ENVELOPE: f64 = 0.0;

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
        let threshold = db_to_gain(ctx.param(THRESHOLD) as f64);
        let exp_ratio = ctx.param(RATIO) as f64;
        let att = smooth_coeff(ctx.param(ATTACK) as f64, sr);
        let rel = smooth_coeff(ctx.param(RELEASE) as f64, sr);
        let range_gain = db_to_gain(ctx.param(RANGE) as f64);

        for i in 0..ctx.frames() {
            let mut peak: f64 = 0.0;
            for c in 0..ctx.channels() {
                let v = (ctx.input(c, i) as f64).abs();
                if v > peak { peak = v; }
            }

            if peak > ENVELOPE {
                ENVELOPE = att * ENVELOPE + (1.0 - att) * peak;
            } else {
                ENVELOPE = rel * ENVELOPE + (1.0 - rel) * peak;
            }

            let gain = if ENVELOPE < threshold && ENVELOPE > 1e-30 {
                let db_below = 20.0 * (threshold / ENVELOPE).log10();
                let db_reduction = db_below * (1.0 - 1.0 / exp_ratio);
                10.0_f64.powf(-db_reduction / 20.0).max(range_gain)
            } else {
                1.0
            };

            for c in 0..ctx.channels() {
                ctx.set_output(c, i, (ctx.input(c, i) as f64 * gain) as f32);
            }
        }
    }
}
