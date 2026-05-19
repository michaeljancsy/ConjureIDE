// Parallel Compression — New York compression.

use conjuredsp::*;
setup!();

params! {
    THRESHOLD = db().min(-40.0).max(-5.0).default(-30.0),
    RATIO = ratio().min(4.0).max(20.0).default(10.0),
    ATTACK = time_ms().min(0.5).max(30.0).default(3.0),
    RELEASE = time_ms().min(20.0).max(300.0).default(80.0),
    BLEND = param(0.0, 1.0).default(0.4),
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
        let comp_ratio = ctx.param(RATIO) as f64;
        let att = smooth_coeff(ctx.param(ATTACK) as f64, sr);
        let rel = smooth_coeff(ctx.param(RELEASE) as f64, sr);
        let blend = ctx.param(BLEND) as f64;

        // Makeup gain
        let makeup = db_to_gain(
            20.0 * (1.0 / threshold + 1e-30).log10() * (1.0 - 1.0 / comp_ratio) * 0.5
        );

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

            let gain = if ENVELOPE > threshold {
                let db_over = 20.0 * (ENVELOPE / threshold + 1e-30).log10();
                let db_red = db_over * (1.0 - 1.0 / comp_ratio);
                10.0_f64.powf(-db_red / 20.0)
            } else {
                1.0
            };

            for c in 0..ctx.channels() {
                let dry = ctx.input(c, i) as f64;
                let compressed = dry * gain * makeup;
                ctx.set_output(c, i, (dry * (1.0 - blend) + compressed * blend) as f32);
            }
        }
    }
}
