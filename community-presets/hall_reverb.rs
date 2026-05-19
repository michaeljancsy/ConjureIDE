// Hall Reverb — large concert hall simulation.
//
// Models the long, smooth decay of a large reverberant space. Uses
// more comb filters with longer delay times and additional allpass
// stages for maximum density.

use conjuredsp::*;
setup!();

params! {
    DECAY = param(1.0, 8.0).unit("s").default(3.0),
    DAMPING = param(0.0, 1.0).default(0.4),
    DIFFUSION = param(0.0, 1.0).default(0.7),
    MIX = mix().default(0.3),
}

const NUM_COMBS: usize = 6;
const NUM_APS: usize = 4;
const COMB_TIMES: [usize; NUM_COMBS] = [1557, 1733, 1907, 2089, 2243, 2399];
const AP_TIMES: [usize; NUM_APS] = [353, 491, 631, 773];

static mut COMBS: [[DelayLine<4096>; NUM_COMBS]; MAX_CH] =
    [[DelayLine::new(); NUM_COMBS]; MAX_CH];
static mut APS: [[DelayLine<1024>; NUM_APS]; MAX_CH] =
    [[DelayLine::new(); NUM_APS]; MAX_CH];
static mut LP_STATE: [[f64; NUM_COMBS]; MAX_CH] = [[0.0; NUM_COMBS]; MAX_CH];

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
        let decay_s = ctx.param(DECAY) as f64;
        let damping = ctx.param(DAMPING) as f64;
        let diffusion = ctx.param(DIFFUSION) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        let damp = damping * 0.55;
        let ap_coeff = 0.3 + diffusion * 0.4;

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
                    let comb_out = COMBS[ch][c].tap(COMB_TIMES[c]) as f64;
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
                    let ap_in = y - ap_coeff * ap_out;
                    APS[ch][a].write(ap_in as f32);
                    y = ap_out + ap_coeff * ap_in;
                }

                let dry = ctx.input(ch, i) as f64;
                ctx.set_output(
                    ch,
                    i,
                    (dry * (1.0 - wet_mix) + y * wet_mix) as f32,
                );
            }
        }
    }
}
