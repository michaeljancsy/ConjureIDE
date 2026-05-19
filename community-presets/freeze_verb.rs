// Freeze Reverb — infinite sustain / sound freeze.
//
// When the freeze toggle is engaged, the reverb feedback goes to
// unity (1.0) and new input is blocked -- the current reverb tail
// sustains infinitely. Release freeze to let it decay naturally.

use conjuredsp::*;
setup!();

params! {
    FREEZE = toggle().default(0.0),
    BLUR = param(0.0, 1.0).default(0.5),
    MIX = mix().default(0.5),
}

const NUM_COMBS: usize = 6;
const NUM_APS: usize = 3;
const COMB_TIMES: [usize; NUM_COMBS] = [1259, 1433, 1601, 1777, 1949, 2111];
const AP_TIMES: [usize; NUM_APS] = [293, 401, 521];

static mut COMBS: [[DelayLine<4096>; NUM_COMBS]; MAX_CH] =
    [[DelayLine::new(); NUM_COMBS]; MAX_CH];
static mut APS: [[DelayLine<1024>; NUM_APS]; MAX_CH] =
    [[DelayLine::new(); NUM_APS]; MAX_CH];

#[no_mangle]
pub extern "C" fn process(
    input: *const f32,
    output: *mut f32,
    channels: i32,
    frame_count: i32,
    sample_rate: f32,
) {
    let ctx = ctx(input, output, channels, frame_count, sample_rate);

    unsafe {
        let frozen = ctx.param(FREEZE) > 0.5;
        let blur = ctx.param(BLUR) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        // When frozen: feedback = 1.0, no new input
        // When not frozen: normal reverb with moderate decay
        let feedback = if frozen { 1.0_f64 } else { 0.85 };
        let input_gain = if frozen { 0.0_f64 } else { 1.0 };
        let ap_coeff = 0.3 + blur * 0.4;

        for ch in 0..ctx.channels() {
            for i in 0..ctx.frames() {
                let x = ctx.input(ch, i) as f64 * input_gain;

                let mut comb_sum = 0.0_f64;
                for c in 0..NUM_COMBS {
                    let comb_out = COMBS[ch][c].tap(COMB_TIMES[c]) as f64;
                    COMBS[ch][c]
                        .write((x + comb_out * feedback) as f32);
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
