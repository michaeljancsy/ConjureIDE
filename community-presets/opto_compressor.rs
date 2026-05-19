// Opto Compressor — LA-2A style optical compressor.

use conjuredsp::*;
setup!();

params! {
    PEAK_REDUCTION = db().min(0.0).max(40.0).default(15.0),
    GAIN = db().min(0.0).max(30.0).default(10.0),
    SPEED = param(0.0, 1.0).default(0.5),
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
        let peak_red_db = ctx.param(PEAK_REDUCTION) as f64;
        let makeup = db_to_gain(ctx.param(GAIN) as f64);
        let speed = ctx.param(SPEED) as f64;

        let attack_ms = 10.0 - speed * 8.5;
        let release_ms = 500.0 - speed * 460.0;

        let att = smooth_coeff(attack_ms, sr);
        let rel = smooth_coeff(release_ms, sr);

        let threshold = db_to_gain(-peak_red_db);

        for i in 0..ctx.frames() {
            let mut peak: f64 = 0.0;
            for c in 0..ctx.channels() {
                let v = (ctx.input(c, i) as f64).abs();
                if v > peak { peak = v; }
            }

            let level_factor = 1.0 + peak * 2.0;
            if peak > ENVELOPE {
                ENVELOPE = att * ENVELOPE + (1.0 - att) * peak * level_factor;
                ENVELOPE = ENVELOPE.min(peak);
            } else {
                ENVELOPE = rel * ENVELOPE + (1.0 - rel) * peak;
            }

            let gain = if ENVELOPE > threshold && ENVELOPE > 1e-10 {
                let ratio_db = 20.0 * (ENVELOPE / threshold + 1e-30).log10();
                let effective_ratio = 2.0 + ratio_db * 0.3;
                let db_reduction = ratio_db * (1.0 - 1.0 / effective_ratio);
                10.0_f64.powf(-db_reduction / 20.0)
            } else {
                1.0
            };

            for c in 0..ctx.channels() {
                ctx.set_output(c, i, (ctx.input(c, i) as f64 * gain * makeup) as f32);
            }
        }
    }
}
