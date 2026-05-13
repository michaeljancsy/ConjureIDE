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
params! {
    THRESHOLD = db().min(-80.0).max(-20.0).default(-40.0),
    ATTACK = time_ms().min(0.1).max(10.0).default(1.0),
    RELEASE = time_ms().min(10.0).max(500.0).default(100.0),
    HOLD = time_ms().min(0.1).max(100.0).default(10.0),
}

// Persistent state. f64 to match Python's float64 precision in the
// envelope feedback loop.
persist!(ENVELOPE: f64 = 0.0);
persist!(HOLD_COUNTER: i32 = 0);

process! { ctx =>
    let sr = ctx.sample_rate() as f64;

    let threshold_db = ctx.param(THRESHOLD) as f64;
    let attack_ms = ctx.param(ATTACK) as f64;
    let release_ms = ctx.param(RELEASE) as f64;
    let hold_ms = ctx.param(HOLD) as f64;

    let threshold = db_to_gain(threshold_db);
    let attack_coeff = smooth_coeff(attack_ms, sr);
    let release_coeff = smooth_coeff(release_ms, sr);
    let hold_samples = (hold_ms * 0.001 * sr) as i32;
    let mut env = ENVELOPE.get();
    let mut hold = HOLD_COUNTER.get();

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

    ENVELOPE.set(env);
    HOLD_COUNTER.set(hold);
}
