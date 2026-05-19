// Shimmer Reverb — pitch-shifted ethereal reverb tails.
//
// Combines a lush reverb with octave-up pitch shifting in the
// feedback loop. Each cycle through the reverb, the signal shifts
// up, creating infinite ascending crystalline tails.

use conjuredsp::*;
setup!();

params! {
    DECAY = param(1.0, 10.0).unit("s").default(4.0),
    SHIMMER = param(0.0, 1.0).default(0.6),
    DAMPING = param(0.0, 1.0).default(0.3),
    MIX = mix().default(0.4),
}

const NUM_COMBS: usize = 4;
const NUM_APS: usize = 2;
const COMB_TIMES: [usize; NUM_COMBS] = [1187, 1307, 1439, 1553];
const AP_TIMES: [usize; NUM_APS] = [277, 389];

static mut COMBS: [[DelayLine<2048>; NUM_COMBS]; MAX_CH] =
    [[DelayLine::new(); NUM_COMBS]; MAX_CH];
static mut APS: [[DelayLine<512>; NUM_APS]; MAX_CH] =
    [[DelayLine::new(); NUM_APS]; MAX_CH];
static mut LP_STATE: [[f64; NUM_COMBS]; MAX_CH] = [[0.0; NUM_COMBS]; MAX_CH];
static mut SHIMMER_PHASE: [f64; MAX_CH] = [0.0; MAX_CH];

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
    let two_pi = 2.0 * core::f64::consts::PI;

    unsafe {
        let decay_s = ctx.param(DECAY) as f64;
        let shimmer = ctx.param(SHIMMER) as f64;
        let damping = ctx.param(DAMPING) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        let damp = damping * 0.5;

        let mut comb_gains = [0.0_f64; NUM_COMBS];
        for c in 0..NUM_COMBS {
            if decay_s > 0.0 {
                comb_gains[c] =
                    10.0_f64.powf(-3.0 * COMB_TIMES[c] as f64 / (decay_s * sr));
            }
        }

        for ch in 0..ctx.channels() {
            for i in 0..ctx.frames() {
                let x = ctx.input(ch, i) as f64;

                // Parallel comb filters
                let mut comb_sum = 0.0_f64;
                for c in 0..NUM_COMBS {
                    let comb_out = COMBS[ch][c].tap(COMB_TIMES[c]) as f64;

                    // Damping in feedback
                    LP_STATE[ch][c] =
                        LP_STATE[ch][c] * damp + comb_out * (1.0 - damp);

                    // Shimmer: ring-mod octave up in feedback
                    let shimmer_sig = LP_STATE[ch][c]
                        * (two_pi * SHIMMER_PHASE[ch] * 2.0).sin();
                    let fb = LP_STATE[ch][c] * (1.0 - shimmer)
                        + shimmer_sig * shimmer;

                    COMBS[ch][c].write((x + fb * comb_gains[c]) as f32);
                    comb_sum += comb_out;
                }

                comb_sum /= NUM_COMBS as f64;

                // Allpass diffusers
                let mut y = comb_sum;
                for a in 0..NUM_APS {
                    let ap_out = APS[ch][a].tap(AP_TIMES[a]) as f64;
                    let ap_in = y - 0.5 * ap_out;
                    APS[ch][a].write(ap_in as f32);
                    y = ap_out + 0.5 * ap_in;
                }

                let dry = ctx.input(ch, i) as f64;
                ctx.set_output(
                    ch,
                    i,
                    (dry * (1.0 - wet_mix) + y * wet_mix) as f32,
                );
            }

            SHIMMER_PHASE[ch] =
                (SHIMMER_PHASE[ch] + 440.0 / sr) % 1.0;
        }
    }
}
