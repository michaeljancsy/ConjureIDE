// Ducker — auto-ducking for podcasts and voiceover.

use conjuredsp::*;
setup!();

params! {
    THRESHOLD = db().min(-40.0).max(-5.0).default(-25.0),
    DUCK = db().min(-30.0).max(0.0).default(-15.0),
    ATTACK = time_ms().min(1.0).max(50.0).default(5.0),
    HOLD = time_ms().min(10.0).max(1000.0).default(200.0),
    RELEASE = time_ms().min(50.0).max(2000.0).default(500.0),
}

static mut ENVELOPE: f64 = 0.0;
static mut HOLD_COUNTER: i32 = 0;
static mut GATE_OPEN: bool = false;

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
        let duck_gain = db_to_gain(ctx.param(DUCK) as f64);
        let att = smooth_coeff(ctx.param(ATTACK) as f64, sr);
        let rel = smooth_coeff(ctx.param(RELEASE) as f64, sr);
        let hold_samples = (ctx.param(HOLD) as f64 * 0.001 * sr) as i32;

        for i in 0..ctx.frames() {
            let mut peak: f64 = 0.0;
            for c in 0..ctx.channels() {
                let v = (ctx.input(c, i) as f64).abs();
                if v > peak { peak = v; }
            }

            if peak > threshold {
                GATE_OPEN = true;
                HOLD_COUNTER = hold_samples;
            }

            if HOLD_COUNTER > 0 {
                HOLD_COUNTER -= 1;
            } else {
                GATE_OPEN = false;
            }

            let target = if GATE_OPEN { duck_gain } else { 1.0 };
            if target < ENVELOPE {
                ENVELOPE = att * ENVELOPE + (1.0 - att) * target;
            } else {
                ENVELOPE = rel * ENVELOPE + (1.0 - rel) * target;
            }

            for c in 0..ctx.channels() {
                ctx.set_output(c, i, (ctx.input(c, i) as f64 * ENVELOPE) as f32);
            }
        }
    }
}
