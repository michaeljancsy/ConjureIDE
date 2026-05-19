// Noise Suppressor — intelligent noise gate for guitar/bass.
//
// A smooth, musical noise gate designed for guitar rigs. Fast
// attack preserves pick transients, adjustable release prevents
// choppy cutoffs, and the reduction control allows partial
// attenuation instead of hard silence. Placed after distortion
// in the chain, it tames amplifier and pedal noise during pauses.
// Think ISP Decimator or Boss NS-2.
//
// Params:
//   threshold: Gate open threshold (-80 to -20 dB)
//   reduction: Maximum noise reduction (-60 to 0 dB)
//   attack:    Gate open speed (0.1-5 ms)
//   release:   Gate close speed (10-500 ms)

use conjuredsp::*;
setup!();

params! {
    THRESHOLD = db().min(-80.0).max(-20.0).default(-50.0),
    REDUCTION = db().min(-60.0).max(0.0).default(-30.0),
    ATTACK = time_ms().min(0.1).max(5.0).default(0.5),
    RELEASE = time_ms().min(10.0).max(500.0).default(50.0),
}

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
        let thresh = db_to_gain(ctx.param(THRESHOLD) as f64);
        let reduction = db_to_gain(ctx.param(REDUCTION) as f64);
        let att = smooth_coeff(ctx.param(ATTACK) as f64, sr);
        let rel = smooth_coeff(ctx.param(RELEASE) as f64, sr);

        let mut env = ENVELOPE;

        for i in 0..ctx.frames() {
            let mut peak: f64 = 0.0;
            for ch in 0..ctx.channels() {
                let abs_val = (ctx.input(ch, i) as f64).abs();
                if abs_val > peak {
                    peak = abs_val;
                }
            }

            if peak > env {
                env = att * env + (1.0 - att) * peak;
            } else {
                env = rel * env + (1.0 - rel) * peak;
            }

            let gain: f64;
            if env > thresh {
                gain = 1.0;
            } else {
                // Smooth transition from full signal to reduced
                let ratio = env / (thresh + 1e-30);
                gain = reduction + (1.0 - reduction) * ratio;
            }

            for ch in 0..ctx.channels() {
                ctx.set_output(ch, i, (ctx.input(ch, i) as f64 * gain) as f32);
            }
        }

        ENVELOPE = env;
    }
}
