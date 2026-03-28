// Compressor — dynamic range compression with envelope follower.
//
// Reduces the dynamic range of the audio signal using a peak-detecting
// envelope follower. When the signal exceeds the threshold, gain is reduced
// according to the compression ratio. Attack and release times control how
// quickly the compressor responds to level changes. Makeup gain compensates
// for the overall volume reduction caused by compression.
//
// The envelope follower operates per-sample across all channels (peak detection),
// so stereo signals are compressed with linked gain to preserve the stereo image.
//
// Params:
//   0 (Threshold): Compression threshold — -40 to -3 dB
//   1 (Ratio):     Compression ratio — 2:1 to 20:1
//   2 (Attack):    Attack time — 0.5 to 50 ms
//   3 (Release):   Release time — 10 to 500 ms
//   4 (Makeup):    Makeup gain — 0 to 20 dB

use conjuredsp::*;
setup!();

params! {
    THRESHOLD = db().min(-40.0).max(-3.0).default(-20.0),
    RATIO = ratio().min(2.0).max(20.0).default(4.0),
    ATTACK = time_ms().min(0.5).max(50.0).default(5.0),
    RELEASE = time_ms().min(10.0).max(500.0).default(50.0),
    MAKEUP = db().min(0.0).max(20.0).default(0.0),
}

// Persistent envelope follower state
// Use f64 to match Python's float64 precision in the envelope feedback loop.
static mut ENVELOPE: f64 = 0.0;

/// Compressor — dynamic range compression with envelope follower.
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
        let ratio = ctx.param(RATIO) as f64;
        let attack_ms = ctx.param(ATTACK) as f64;
        let release_ms = ctx.param(RELEASE) as f64;
        let makeup_db = ctx.param(MAKEUP) as f64;

        let threshold = db_to_gain(threshold_db);
        let makeup = db_to_gain(makeup_db);
        let attack_coeff = smooth_coeff(attack_ms, sr);
        let release_coeff = smooth_coeff(release_ms, sr);
        let mut env = ENVELOPE;

        for i in 0..ctx.frames() {
            // Peak detect across all channels
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

            // Gain computation
            let gain = if env > threshold {
                let db_over = gain_to_db(env) - gain_to_db(threshold);
                let db_reduction = db_over * (1.0 - 1.0 / ratio);
                db_to_gain(-db_reduction)
            } else {
                1.0
            };

            for c in 0..ctx.channels() {
                ctx.set_output(c, i, (ctx.input(c, i) as f64 * gain * makeup) as f32);
            }
        }

        ENVELOPE = env;
    }
}
