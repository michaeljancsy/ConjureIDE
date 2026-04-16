// Auto-Wah — envelope-controlled bandpass filter.
//
// An envelope follower tracks the input level and sweeps a resonant
// bandpass filter across a frequency range. Louder playing pushes the
// filter higher; quiet passages bring it back down. The result is the
// classic funk/synth wah effect driven by playing dynamics.
//
// Params:
//   0 (Sensitivity): Input gain for envelope detection — -40 to 0 dB
//   1 (Depth):       Frequency sweep range — 0 to 100%
//   2 (Min Freq):    Lowest filter frequency — 200 to 800 Hz (log)
//   3 (Max Freq):    Highest filter frequency — 1000 to 8000 Hz (log)
//   4 (Q):           Filter resonance — 0.5 to 10
//   5 (Attack):      Envelope attack time — 0.5 to 50 ms (log)
//   6 (Release):     Envelope release time — 10 to 500 ms (log)

use conjuredsp::*;
setup!();

params! {
    SENSITIVITY = db().min(-40.0).max(0.0).default(-20.0),
    DEPTH = pct().default(80.0),
    MIN_FREQ = freq().min(200.0).max(800.0).default(400.0),
    MAX_FREQ = freq().min(1000.0).max(8000.0).default(3000.0),
    Q = param(0.5, 10.0).default(3.0),
    ATTACK = time_ms().min(0.5).max(50.0).default(5.0),
    RELEASE = time_ms().min(10.0).max(500.0).default(50.0),
}

// Biquad state per channel
static mut FILTERS: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];

// Envelope follower
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
        let sensitivity_gain = db_to_gain(ctx.param(SENSITIVITY) as f64);
        let depth = ctx.param(DEPTH) as f64 / 100.0;
        let min_freq = ctx.param(MIN_FREQ) as f64;
        let max_freq = ctx.param(MAX_FREQ) as f64;
        let q = ctx.param(Q) as f64;
        let attack_ms = ctx.param(ATTACK) as f64;
        let release_ms = ctx.param(RELEASE) as f64;

        let attack_coeff = smooth_coeff(attack_ms, sr);
        let release_coeff = smooth_coeff(release_ms, sr);

        let freq_range = max_freq - min_freq;

        let mut env = ENVELOPE;

        for i in 0..ctx.frames() {
            // Peak detect across channels with sensitivity scaling
            let mut peak_val: f64 = 0.0;
            for c in 0..ctx.channels() {
                let abs_val = (ctx.input(c, i) as f64).abs() * sensitivity_gain;
                if abs_val > peak_val {
                    peak_val = abs_val;
                }
            }

            // Envelope follower
            if peak_val > env {
                env = attack_coeff * env + (1.0 - attack_coeff) * peak_val;
            } else {
                env = release_coeff * env + (1.0 - release_coeff) * peak_val;
            }

            // Map envelope to filter frequency
            let mut env_clamped = env;
            if env_clamped < 0.0 {
                env_clamped = 0.0;
            }
            if env_clamped > 1.0 {
                env_clamped = 1.0;
            }
            let wah_freq = min_freq + depth * freq_range * env_clamped;

            // Compute bandpass coefficients per sample
            let bp = BiquadCoeffs::bandpass(wah_freq, q, sr);

            for c in 0..ctx.channels() {
                let x = ctx.input(c, i) as f64;
                FILTERS[c].set_coeffs(bp);
                ctx.set_output(c, i, FILTERS[c].process_sample(x) as f32);
            }
        }

        ENVELOPE = env;
    }
}
