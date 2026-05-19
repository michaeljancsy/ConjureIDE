// Compressor Sustainer — guitar sustain pedal.
//
// Designed for guitar: heavy compression that extends note sustain
// while keeping the attack natural. The sustain knob controls
// compression intensity. The attack control determines how much
// pick transient comes through. At high sustain, notes ring out
// endlessly. The foundation of every guitarist's pedalboard —
// think MXR Dyna Comp, Ross Compressor, or Keeley Compressor.
//
// Params:
//   sustain: Compression amount (0 = light, 1 = infinite sustain)
//   attack:  Transient preservation (0 = squashed, 1 = natural pick)
//   level:   Output level (-12 to +6 dB)

use conjuredsp::*;
setup!();

params! {
    SUSTAIN = param(0.0, 1.0).default(0.6),
    ATTACK = param(0.0, 1.0).default(0.3),
    LEVEL = db().min(-12.0).max(6.0).default(0.0),
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
        let sustain = ctx.param(SUSTAIN) as f64;
        let attack = ctx.param(ATTACK) as f64;
        let level = db_to_gain(ctx.param(LEVEL) as f64);

        // Map sustain to compression parameters
        let threshold = db_to_gain(-5.0 - sustain * 35.0);
        let comp_ratio = 2.0 + sustain * 18.0;

        let attack_ms = 0.5 + attack * 30.0;
        let release_ms = 50.0 + sustain * 300.0;

        let att = smooth_coeff(attack_ms, sr);
        let rel = smooth_coeff(release_ms, sr);

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

            let mut gain = 1.0_f64;
            if env > threshold {
                let db_over = 20.0 * (env / threshold + 1e-30).ln() / core::f64::consts::LN_10;
                let db_red = db_over * (1.0 - 1.0 / comp_ratio);
                gain = 10.0_f64.powf(-db_red / 20.0);
            }

            // Auto makeup based on threshold
            let mut thresh_clamped = threshold;
            if thresh_clamped < 0.01 {
                thresh_clamped = 0.01;
            }
            let makeup = 1.0 / thresh_clamped * 0.3;

            for ch in 0..ctx.channels() {
                ctx.set_output(ch, i, (ctx.input(ch, i) as f64 * gain * makeup * level) as f32);
            }
        }

        ENVELOPE = env;
    }
}
