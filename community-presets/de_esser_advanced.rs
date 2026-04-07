// De-Esser Advanced — frequency-selective sibilance reducer.
//
// Detects sibilant frequencies (harsh "s" and "t" sounds) and
// dynamically reduces them. This version has adjustable frequency
// targeting and a range control to limit maximum reduction. The
// listen parameter lets you audition just the sibilant band to
// dial in the frequency. Essential for vocal mixing, podcast
// production, and dialogue.
//
// Params:
//   frequency: Sibilance detection frequency (3-10 kHz)
//   threshold: Level above which de-essing engages (-30 to 0 dB)
//   range:     Maximum sibilance reduction (-20 to 0 dB)
//   listen:    Monitor the sibilant band only (0 = normal, 1 = listen)

use conjuredsp::*;
setup!();

params! {
    FREQUENCY = freq().min(3000.0).max(10000.0).default(6000.0),
    THRESHOLD = db().min(-30.0).max(0.0).default(-15.0),
    RANGE = db().min(-20.0).max(0.0).default(-10.0),
    LISTEN = param(0.0, 1.0).default(0.0),
}

static mut BP: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
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
        let center = ctx.param(FREQUENCY) as f64;
        let thresh = db_to_gain(ctx.param(THRESHOLD) as f64);
        let max_reduction = db_to_gain(ctx.param(RANGE) as f64);
        let listen = ctx.param(LISTEN) as f64;

        let att = smooth_coeff(0.5, sr);
        let rel = smooth_coeff(10.0, sr);

        let bp_coeffs = BiquadCoeffs::bandpass(center, 3.0, sr);
        for ch in 0..ctx.channels() {
            BP[ch].set_coeffs(bp_coeffs);
        }

        let mut env = ENVELOPE;

        for i in 0..ctx.frames() {
            // Detect sibilant energy
            let mut sib_energy: f64 = 0.0;
            for ch in 0..ctx.channels() {
                let sib = BP[ch].process_sample(ctx.input(ch, i) as f64);
                let abs_sib = sib.abs();
                if abs_sib > sib_energy {
                    sib_energy = abs_sib;
                }
            }

            // Envelope follower
            if sib_energy > env {
                env = att * env + (1.0 - att) * sib_energy;
            } else {
                env = rel * env + (1.0 - rel) * sib_energy;
            }

            // Gain reduction when sibilance exceeds threshold
            let gain: f64;
            if env > thresh {
                let overshoot = env / thresh;
                let mut g = 1.0 / overshoot;
                if g < max_reduction {
                    g = max_reduction;
                }
                gain = g;
            } else {
                gain = 1.0;
            }

            for ch in 0..ctx.channels() {
                if listen > 0.5 {
                    // Listen mode: hear only the sibilant band
                    // Note: Python calls process_sample again here on the same filter,
                    // which processes the sample a second time through the stateful filter.
                    let sib = BP[ch].process_sample(ctx.input(ch, i) as f64);
                    ctx.set_output(ch, i, (sib * 3.0) as f32);
                } else {
                    // Apply gain reduction to sibilant frequencies only
                    let sib = BP[ch].process_sample(ctx.input(ch, i) as f64);
                    ctx.set_output(ch, i, (ctx.input(ch, i) as f64 - sib * (1.0 - gain)) as f32);
                }
            }
        }

        ENVELOPE = env;
    }
}
