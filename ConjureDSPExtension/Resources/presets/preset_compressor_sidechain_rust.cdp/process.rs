// Sidechain compressor — keys gain reduction off the second input bus
// when the host has one routed, otherwise falls back to the main input
// (so the preset still does something musical when no sidechain is
// wired). Same gain-computation core as the regular compressor preset;
// the only difference is which signal drives the envelope follower.
//
// Params:
//   0 (Threshold): Compression threshold — -40 to -3 dB
//   1 (Ratio):     Compression ratio — 2:1 to 20:1
//   2 (Attack):    Attack time — 0.5 to 50 ms
//   3 (Release):   Release time — 10 to 500 ms
//   4 (Makeup):    Makeup gain — 0 to 20 dB

use conjuredsp::*;
params! {
    THRESHOLD = db().min(-40.0).max(-3.0).default(-20.0),
    RATIO = ratio().min(2.0).max(20.0).default(4.0),
    ATTACK = time_ms().min(0.5).max(50.0).default(5.0),
    RELEASE = time_ms().min(10.0).max(500.0).default(80.0),
    MAKEUP = db().min(0.0).max(20.0).default(0.0),
}

telemetry! {
    GR_DB    = scalar_telemetry().unit("dB"),  // worst-case gain reduction in this block, ≥0
    ENV_DB   = scalar_telemetry().unit("dB"),  // envelope follower output at end of block
    SC_ACTIVE = scalar_telemetry().unit(""),   // 1.0 when keying off sidechain, 0.0 when internal
    GR_CURVE = vector_telemetry().unit("dB"),  // per-sample GR (≥0) — UI scope draws the envelope shape
}

// Persistent envelope follower state.
static mut ENVELOPE: f64 = 0.0;

// Per-block GR scratch for vector telemetry.
static mut GR_SCRATCH: [f32; MAX_FR] = [0.0; MAX_FR];

process! { ctx =>
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
        let mut max_gr_db: f64 = 0.0;

        let sc_active = ctx.sidechain_connected();
        let sc_channels = ctx.sidechain_channels();

        for i in 0..ctx.frames() {
            // Detection signal: prefer sidechain when host has one
            // routed; fall back to peak of main input across all
            // channels otherwise. Stereo SC also peak-detected so the
            // gain reduction stays linked across the output.
            let mut peak: f64 = 0.0;
            if sc_active {
                for c in 0..sc_channels {
                    let abs_val = (ctx.sidechain(c, i) as f64).abs();
                    if abs_val > peak {
                        peak = abs_val;
                    }
                }
            } else {
                for c in 0..ctx.channels() {
                    let abs_val = (ctx.input(c, i) as f64).abs();
                    if abs_val > peak {
                        peak = abs_val;
                    }
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

            // Always apply gain reduction to the MAIN input — the
            // sidechain is detection-only, never heard at the output.
            for c in 0..ctx.channels() {
                ctx.set_output(c, i, (ctx.input(c, i) as f64 * gain * makeup) as f32);
            }
        }

        ENVELOPE = env;

        let env_db = if env > 0.0 { gain_to_db(env) } else { -120.0 };
        ctx.set_telemetry_scalar(GR_DB, max_gr_db as f32);
        ctx.set_telemetry_scalar(ENV_DB, env_db as f32);
        ctx.set_telemetry_scalar(SC_ACTIVE, if sc_active { 1.0 } else { 0.0 });
        ctx.set_telemetry_vector(GR_CURVE, &GR_SCRATCH[..ctx.frames()]);
    }
}
