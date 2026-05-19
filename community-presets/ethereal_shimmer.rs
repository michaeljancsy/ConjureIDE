// Ethereal Shimmer -- lush shimmer pad creator.
//
// Combines an ultra-long reverb with modulation and pitch shimmer
// to transform any input into an ethereal, crystalline pad.

use conjuredsp::*;
setup!();

params! {
    DECAY = param(3.0, 20.0).unit("s").default(8.0),
    SPARKLE = param(0.0, 1.0).default(0.6),
    MODULATION = param(0.0, 1.0).default(0.5),
    MIX = mix().default(0.7),
}

const NUM_COMBS: usize = 6;
const NUM_APS: usize = 3;
const COMB_TIMES: [usize; NUM_COMBS] = [1297, 1451, 1619, 1783, 1949, 2099];
const AP_TIMES: [usize; NUM_APS] = [307, 419, 547];
const MOD_RATES: [f64; NUM_COMBS] = [0.23, 0.37, 0.53, 0.19, 0.41, 0.31];

static mut COMBS: [[DelayLine<4096>; NUM_COMBS]; MAX_CH] =
    [[DelayLine::new(); NUM_COMBS]; MAX_CH];
static mut APS: [[DelayLine<1024>; NUM_APS]; MAX_CH] =
    [[DelayLine::new(); NUM_APS]; MAX_CH];
static mut LP_STATE: [[f64; NUM_COMBS]; MAX_CH] = [[0.0; NUM_COMBS]; MAX_CH];
static mut MOD_PHASES: [f64; NUM_COMBS] = [0.0; NUM_COMBS];
static mut SHIMMER_PHASE: f64 = 0.0;
static mut INITIALIZED: bool = false;

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
        let sparkle = ctx.param(SPARKLE) as f64;
        let modulation = ctx.param(MODULATION) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        // Initialize mod phases (matching Python: i * 0.17)
        if !INITIALIZED {
            for idx in 0..NUM_COMBS {
                MOD_PHASES[idx] = idx as f64 * 0.17;
            }
            INITIALIZED = true;
        }

        let mut comb_gains = [0.0_f64; NUM_COMBS];
        for c in 0..NUM_COMBS {
            if decay_s > 0.0 {
                comb_gains[c] =
                    10.0_f64.powf(-3.0 * COMB_TIMES[c] as f64 / (decay_s * sr));
            }
        }

        let mod_depth = modulation * 5.0;

        for ch in 0..ctx.channels() {
            for i in 0..ctx.frames() {
                let x = ctx.input(ch, i) as f64;

                let mut comb_sum = 0.0_f64;
                for c in 0..NUM_COMBS {
                    let modv = (two_pi * MOD_PHASES[c]).sin() * mod_depth;
                    let read_time = (COMB_TIMES[c] as f64 + modv).max(1.0);

                    let comb_out = COMBS[ch][c].read(read_time) as f64;

                    // Light damping
                    LP_STATE[ch][c] = LP_STATE[ch][c] * 0.2 + comb_out * 0.8;

                    // Shimmer in feedback
                    let shimmer_sig =
                        LP_STATE[ch][c] * (two_pi * SHIMMER_PHASE * 2.0).sin();
                    let fb = LP_STATE[ch][c] * (1.0 - sparkle)
                        + shimmer_sig * sparkle;

                    COMBS[ch][c].write((x + fb * comb_gains[c]) as f32);
                    comb_sum += comb_out;
                }

                comb_sum /= NUM_COMBS as f64;

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
        }

        // Advance shimmer phase
        SHIMMER_PHASE = (SHIMMER_PHASE + 440.0 / sr) % 1.0;

        // Advance mod phases
        for c in 0..NUM_COMBS {
            MOD_PHASES[c] = (MOD_PHASES[c] + MOD_RATES[c] / sr) % 1.0;
        }
    }
}
