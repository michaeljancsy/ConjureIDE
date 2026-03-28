// Noise Gate — silences signal below a threshold.
//
// Monitors the peak level across all channels. When the level drops
// below the threshold, the gate closes (attenuates to silence) after
// a hold period. Attack and release control how quickly the gate
// opens and closes. The hold time prevents the gate from chattering
// on signals that hover near the threshold.
//
// Params:
//   0 (Threshold): Gate threshold — -80 to -20 dB
//   1 (Attack):    Attack time — 0.1 to 10 ms
//   2 (Release):   Release time — 10 to 500 ms
//   3 (Hold):      Hold time — 0 to 100 ms

use conjuredsp::*;
setup!();

params! {
    THRESHOLD = db().min(-80.0).max(-20.0).default(-40.0),
    ATTACK = param(0.1, 10.0).unit("ms").default(1.0),
    RELEASE = param(10.0, 500.0).unit("ms").default(100.0),
    HOLD = param(0.0, 100.0).unit("ms").default(10.0),
}

// Persistent state
// Use f64 to match Python's float64 precision in the envelope feedback loop.
static mut ENVELOPE: f64 = 0.0;
static mut HOLD_COUNTER: i32 = 0;

#[no_mangle]
pub extern "C" fn process(
    input: *const f32,
    output: *mut f32,
    channels: i32,
    frame_count: i32,
    sample_rate: f32,
) {
    let ctx = ctx(input, output, channels, frame_count, sample_rate);
    let sr = ctx.sample_rate() as f64;

    unsafe {
        let threshold_db = ctx.param(THRESHOLD) as f64;
        let attack_ms = ctx.param(ATTACK) as f64;
        let release_ms = ctx.param(RELEASE) as f64;
        let hold_ms = ctx.param(HOLD) as f64;

        let threshold = db_to_gain(threshold_db);
        let attack_coeff = smooth_coeff(attack_ms, sr);
        let release_coeff = smooth_coeff(release_ms, sr);
        let hold_samples = (hold_ms * 0.001 * sr) as i32;
        let mut env = ENVELOPE;
        let mut hold = HOLD_COUNTER;

        for i in 0..ctx.frames() {
            // Peak detect across all channels
            let mut peak: f64 = 0.0;
            for c in 0..ctx.channels() {
                let abs_val = (ctx.input(c, i) as f64).abs();
                if abs_val > peak {
                    peak = abs_val;
                }
            }

            if peak > threshold {
                // Gate open: envelope approaches 1.0
                env = attack_coeff * env + (1.0 - attack_coeff);
                hold = hold_samples;
            } else if hold > 0 {
                // Hold: maintain current envelope
                hold -= 1;
            } else {
                // Release: envelope approaches 0.0
                env = release_coeff * env;
            }

            for c in 0..ctx.channels() {
                ctx.set_output(c, i, (ctx.input(c, i) as f64 * env) as f32);
            }
        }

        ENVELOPE = env;
        HOLD_COUNTER = hold;
    }
}
