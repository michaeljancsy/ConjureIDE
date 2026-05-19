// Shoegaze Wash — wall of sound shoegaze effect.
//
// Deep modulated chorus with dense reverb for the massive, blurred
// wall of sound that defines shoegaze. Shimmer adds overtone content.

use conjuredsp::*;
setup!();

params! {
    DEPTH = param(0.0, 1.0).default(0.8),
    FEEDBACK = param(0.0, 0.95).default(0.7),
    SHIMMER = param(0.0, 1.0).default(0.5),
    MIX = mix().default(0.8),
}

const MAX_DELAY: usize = 4096;
const COMB_TIMES: [usize; 4] = [1087, 1237, 1381, 1523];

static mut CHORUS_DELAYS: [[DelayLine<MAX_DELAY>; 3]; MAX_CH] = [[DelayLine::new(); 3]; MAX_CH];
static mut REV_COMBS: [[DelayLine<2048>; 4]; MAX_CH] = [[DelayLine::new(); 4]; MAX_CH];
static mut REV_LP: [[f64; 4]; MAX_CH] = [[0.0; 4]; MAX_CH];
static mut PHASES: [f64; 4] = [0.0, 0.12, 0.37, 0.55];

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
        let depth = ctx.param(DEPTH) as f64;
        let feedback = ctx.param(FEEDBACK) as f64;
        let shimmer = ctx.param(SHIMMER) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        let two_pi = 2.0 * core::f64::consts::PI;
        let mod_depth = depth * 8.0;
        let rates: [f64; 3] = [0.3, 0.47, 0.71];

        for ch in 0..ctx.channels() {
            for i in 0..ctx.frames() {
                let x = ctx.input(ch, i) as f64;

                // Deep multi-voice chorus
                let mut chorus_out = 0.0;
                for v in 0..3 {
                    CHORUS_DELAYS[ch][v].write(x as f32);
                    let modulation = (two_pi * PHASES[v]).sin() * mod_depth;
                    let delay = 10.0 + modulation;
                    let delay_clamped = if delay > 1.0 { delay } else { 1.0 };
                    chorus_out += CHORUS_DELAYS[ch][v].read_cubic(delay_clamped) as f64;
                }
                chorus_out /= 3.0;

                // Dense reverb
                let rev_in = (x + chorus_out) * 0.5;
                let mut rev_out = 0.0;
                for c in 0..4 {
                    let comb_out = REV_COMBS[ch][c].tap(COMB_TIMES[c]) as f64;
                    REV_LP[ch][c] = REV_LP[ch][c] * 0.3 + comb_out * 0.7;

                    // Shimmer in reverb feedback
                    let mut fb_signal = REV_LP[ch][c];
                    if shimmer > 0.0 {
                        fb_signal = fb_signal * (1.0 - shimmer * 0.3)
                            + fb_signal.abs() * shimmer * 0.3;
                    }

                    REV_COMBS[ch][c].write((rev_in + fb_signal * feedback) as f32);
                    rev_out += comb_out;
                }
                rev_out /= 4.0;

                let wet = chorus_out * 0.4 + rev_out * 0.6;
                ctx.set_output(
                    ch,
                    i,
                    (x * (1.0 - wet_mix) + wet * wet_mix) as f32,
                );
            }
        }

        // Update phases after all channels processed
        for v in 0..PHASES.len() {
            let r = if v < rates.len() { rates[v] } else { 0.5 };
            PHASES[v] = (PHASES[v] + r / sr) % 1.0;
        }
    }
}
