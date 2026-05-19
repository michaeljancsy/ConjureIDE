// Ambient Wash — lush modulated reverb for ambient/textural use.
//
// A long-decay reverb with internal modulation that creates slowly
// evolving, shimmering tails. The modulation prevents metallic
// buildup and adds organic movement to sustained reverb tails.

use conjuredsp::*;
setup!();

params! {
    DECAY = param(2.0, 15.0).unit("s").default(6.0),
    MODULATION = param(0.0, 1.0).default(0.4),
    BRIGHTNESS = param(0.0, 1.0).default(0.5),
    MIX = mix().default(0.6),
}

const NUM_COMBS: usize = 6;
const NUM_APS: usize = 3;
const COMB_TIMES: [usize; NUM_COMBS] = [1423, 1607, 1789, 1973, 2143, 2311];
const AP_TIMES: [usize; NUM_APS] = [311, 443, 577];
const MOD_RATES: [f64; NUM_COMBS] = [0.3, 0.47, 0.71, 0.23, 0.59, 0.37];

static mut COMBS: [[DelayLine<4096>; NUM_COMBS]; MAX_CH] =
    [[DelayLine::new(); NUM_COMBS]; MAX_CH];
static mut APS: [[DelayLine<1024>; NUM_APS]; MAX_CH] =
    [[DelayLine::new(); NUM_APS]; MAX_CH];
static mut LP_STATE: [[f64; NUM_COMBS]; MAX_CH] = [[0.0; NUM_COMBS]; MAX_CH];
static mut MOD_PHASES: [f64; NUM_COMBS] = [0.0, 0.1, 0.2, 0.3, 0.4, 0.5];

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
        let modulation = ctx.param(MODULATION) as f64;
        let brightness = ctx.param(BRIGHTNESS) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        let damp = (1.0 - brightness) * 0.6;
        let mod_depth = modulation * 4.0; // samples of modulation

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

                let mut comb_sum = 0.0_f64;
                for c in 0..NUM_COMBS {
                    // Modulated read position
                    let modv = (two_pi * MOD_PHASES[c]).sin() * mod_depth;
                    let read_time =
                        (COMB_TIMES[c] as f64 + modv).max(1.0);

                    let comb_out = COMBS[ch][c].read(read_time) as f64;
                    LP_STATE[ch][c] =
                        LP_STATE[ch][c] * damp + comb_out * (1.0 - damp);
                    COMBS[ch][c].write(
                        (x + LP_STATE[ch][c] * comb_gains[c]) as f32,
                    );
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

        // Advance mod phases
        for c in 0..NUM_COMBS {
            MOD_PHASES[c] = (MOD_PHASES[c] + MOD_RATES[c] / sr) % 1.0;
        }
    }
}
