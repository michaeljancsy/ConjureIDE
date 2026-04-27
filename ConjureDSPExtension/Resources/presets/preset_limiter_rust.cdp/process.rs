// Limiter — brick-wall peak limiter.
//
// Prevents the signal from exceeding the threshold using a fast-attack
// envelope follower. When the peak level exceeds the threshold, gain
// is reduced so the output stays at the threshold. The ultra-fast attack
// (0.1 ms) catches transients; the slower release allows natural decay.
// Unlike a compressor, the ratio is effectively infinite — nothing
// passes above the ceiling.
//
// Params:
//   0 (Threshold): Ceiling level — -20 to 0 dB
//   1 (Attack):    Attack time — 0.01 to 1.0 ms
//   2 (Release):   Release time — 10 to 500 ms

use conjuredsp::*;
setup!();

params! {
    THRESHOLD = db().min(-20.0).max(0.0).default(-6.0),
    ATTACK = time_ms().min(0.01).max(1.0).default(0.1),
    RELEASE = time_ms().min(10.0).max(500.0).default(100.0),
}

// Persistent envelope follower state
// Use f64 to match Python's float64 precision in the envelope feedback loop.
static mut ENVELOPE: f64 = 0.0;

#[no_mangle]
pub extern "C" fn process(
    input: *const f32,
    output: *mut f32,
    channel_count: i32,
    frame_count: i32,
    sample_rate: f32,
) {
    let ctx = ctx(input, output, channel_count, frame_count, sample_rate);
    let sr = ctx.sample_rate() as f64;

    unsafe {
        let threshold_db = ctx.param(THRESHOLD) as f64;
        let attack_ms = ctx.param(ATTACK) as f64;
        let release_ms = ctx.param(RELEASE) as f64;

        let threshold = db_to_gain(threshold_db);
        let attack_coeff = smooth_coeff(attack_ms, sr);
        let release_coeff = smooth_coeff(release_ms, sr);

        let mut env = ENVELOPE;

        for i in 0..ctx.frames() {
            // Peak detect across all channel_count
            let mut peak: f64 = 0.0;
            for c in 0..ctx.channels() {
                let abs_val = (ctx.input(c, i) as f64).abs();
                if abs_val > peak {
                    peak = abs_val;
                }
            }

            // Envelope follower
            if peak > env {
                env = attack_coeff * env + (1.0 - attack_coeff) * peak;
            } else {
                env = release_coeff * env + (1.0 - release_coeff) * peak;
            }

            // Gain reduction: clamp output to threshold
            // Truncate gain to f32 to match Python's np.float32 gain array.
            let gain: f32 = if env > threshold {
                (threshold / env) as f32
            } else {
                1.0
            };

            for c in 0..ctx.channels() {
                ctx.set_output(c, i, ctx.input(c, i) * gain);
            }
        }

        ENVELOPE = env;
    }
}
