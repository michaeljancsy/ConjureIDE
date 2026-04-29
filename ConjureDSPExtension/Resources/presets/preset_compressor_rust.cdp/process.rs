// Compressor — dynamic range compression with envelope follower.
//
// Reduces the dynamic range of the audio signal using a peak-detecting
// envelope follower. When the signal exceeds the threshold, gain is reduced
// according to the compression ratio. Attack and release times control how
// quickly the compressor responds to level changes. Makeup gain compensates
// for the overall volume reduction caused by compression.
//
// The envelope follower operates per-sample across all channel_count (peak detection),
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

// Telemetry: internal DSP state the UI's GR meter reads via
// frame.telemetry. Replaces the old "peakIn − peakOut + makeup"
// estimate that under-reported during transients (the input peak
// arrives before the envelope follower has finished attacking, so
// peak-aligned arithmetic shows ~0 GR mid-attack). Publishing the
// gain computer's actual decision per block is the only way to get
// a meter that tracks what the compressor is actually doing.
telemetry! {
    GR_DB    = scalar_telemetry().unit("dB"),  // worst-case gain reduction in this block, ≥0
    ENV_DB   = scalar_telemetry().unit("dB"),  // envelope follower output at end of block
    GR_CURVE = vector_telemetry().unit("dB"),  // per-sample GR (≥0) — UI scope draws the envelope shape
}

// Persistent envelope follower state
// Use f64 to match Python's float64 precision in the envelope feedback loop.
static mut ENVELOPE: f64 = 0.0;

// Per-block GR scratch for vector telemetry. One f32 per audio frame in
// the current block (length = frame_count, capped at MAX_FR by the
// macro). Static so we don't heap-alloc per render callback.
static mut GR_SCRATCH: [f32; MAX_FR] = [0.0; MAX_FR];

/// Compressor — dynamic range compression with envelope follower.
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
        let ratio = ctx.param(RATIO) as f64;
        let attack_ms = ctx.param(ATTACK) as f64;
        let release_ms = ctx.param(RELEASE) as f64;
        let makeup_db = ctx.param(MAKEUP) as f64;

        let threshold = db_to_gain(threshold_db);
        let makeup = db_to_gain(makeup_db);
        let attack_coeff = smooth_coeff(attack_ms, sr);
        let release_coeff = smooth_coeff(release_ms, sr);
        let mut env = ENVELOPE;

        // Track the deepest GR over the block for the meter — that's
        // the value users want to see ("how hard is this hitting?"),
        // not the per-sample average.
        let mut max_gr_db: f64 = 0.0;

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

            // Gain computation
            let (gain, gr_db) = if env > threshold {
                let db_over = gain_to_db(env) - gain_to_db(threshold);
                let db_reduction = db_over * (1.0 - 1.0 / ratio);
                (db_to_gain(-db_reduction), db_reduction)
            } else {
                (1.0, 0.0)
            };

            if gr_db > max_gr_db {
                max_gr_db = gr_db;
            }

            GR_SCRATCH[i] = gr_db as f32;

            for c in 0..ctx.channels() {
                ctx.set_output(c, i, (ctx.input(c, i) as f64 * gain * makeup) as f32);
            }
        }

        ENVELOPE = env;

        // Publish telemetry. UI reads frame.telemetry["Gr Db"] and
        // ["Env Db"]. The gain computer's actual decision lands here
        // independent of makeup — meter reads true GR even with
        // heavy makeup pulling output back up.
        let env_db = if env > 0.0 { gain_to_db(env) } else { -120.0 };
        ctx.set_telemetry_scalar(GR_DB, max_gr_db as f32);
        ctx.set_telemetry_scalar(ENV_DB, env_db as f32);
        ctx.set_telemetry_vector(GR_CURVE, &GR_SCRATCH[..ctx.frames()]);
    }
}
