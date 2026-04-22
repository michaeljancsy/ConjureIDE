// De-esser — sibilance reduction via sidechain compression.
//
// A bandpass filter isolates sibilant frequencies from the input signal.
// An envelope follower tracks the level of the isolated band. When it
// exceeds the threshold, gain reduction is applied to the full-band
// original signal, taming harshness without affecting the overall tone.
//
// Params:
//   0 (Frequency): Sibilance center frequency — 2000 to 12000 Hz (log)
//   1 (Q):         Sidechain bandpass Q — 0.5 to 5
//   2 (Threshold): Detection threshold — -40 to 0 dB
//   3 (Reduction): Maximum gain reduction — -20 to 0 dB
//   4 (Attack):    Envelope attack time — 0.1 to 10 ms (log)
//   5 (Release):   Envelope release time — 10 to 200 ms (log)

use conjuredsp::*;
setup!();

params! {
    FREQUENCY = freq().min(2000.0).max(12000.0).default(6000.0),
    Q = param(0.5, 5.0).default(1.5),
    THRESHOLD = db().min(-40.0).max(0.0).default(-20.0),
    REDUCTION = db().min(-20.0).max(0.0).default(-6.0),
    ATTACK = time_ms().min(0.1).max(10.0).default(1.0),
    RELEASE = time_ms().min(10.0).max(200.0).default(50.0),
}

// Sidechain biquad state per channel
static mut SC_FILTERS: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];

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
    let sr = ctx.sample_rate() as f64;

    unsafe {
        let center_freq = ctx.param(FREQUENCY) as f64;
        let q = ctx.param(Q) as f64;
        let threshold_db = ctx.param(THRESHOLD) as f64;
        let reduction_db = ctx.param(REDUCTION) as f64;
        let attack_ms = ctx.param(ATTACK) as f64;
        let release_ms = ctx.param(RELEASE) as f64;

        let threshold_lin = db_to_gain(threshold_db);
        let attack_coeff = smooth_coeff(attack_ms, sr);
        let release_coeff = smooth_coeff(release_ms, sr);

        let bp = BiquadCoeffs::bandpass(center_freq, q, sr);
        for c in 0..ctx.channels() {
            SC_FILTERS[c].set_coeffs(bp);
        }

        let mut env = ENVELOPE;

        for i in 0..ctx.frames() {
            // Sidechain: bandpass filter then peak detect across channels
            let mut sc_peak: f64 = 0.0;
            for c in 0..ctx.channels() {
                let x = ctx.input(c, i) as f64;
                let sc = SC_FILTERS[c].process_sample(x);
                let abs_sc = sc.abs();
                if abs_sc > sc_peak {
                    sc_peak = abs_sc;
                }
            }

            // Envelope follower
            if sc_peak > env {
                env = attack_coeff * env + (1.0 - attack_coeff) * sc_peak;
            } else {
                env = release_coeff * env + (1.0 - release_coeff) * sc_peak;
            }

            // Gain computation
            let gain = if env > threshold_lin {
                let over_db = gain_to_db(env) - gain_to_db(threshold_lin);
                let mut over_ratio = over_db / 6.0;
                if over_ratio > 1.0 {
                    over_ratio = 1.0;
                }
                if over_ratio < 0.0 {
                    over_ratio = 0.0;
                }
                db_to_gain(reduction_db * over_ratio)
            } else {
                1.0
            };

            for c in 0..ctx.channels() {
                ctx.set_output(c, i, (ctx.input(c, i) as f64 * gain) as f32);
            }
        }

        ENVELOPE = env;
    }
}
