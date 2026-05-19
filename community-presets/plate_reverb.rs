// Plate Reverb — EMT 140 inspired metallic plate simulation.
//
// Models a vibrating metal plate using parallel comb filters feeding
// into series allpass diffusers. Dense, bright, slightly metallic
// character perfect for vocals, snare, and keyboards.

use conjuredsp::*;
setup!();

params! {
    DECAY = param(0.2, 5.0).unit("s").default(1.5),
    DAMPING = param(0.0, 1.0).default(0.4),
    PREDELAY = param(0.0, 50.0).unit("ms").default(10.0),
    MIX = mix().default(0.3),
}

const NUM_COMBS: usize = 6;
const NUM_APS: usize = 3;
const COMB_TIMES: [usize; NUM_COMBS] = [1117, 1277, 1399, 1523, 1637, 1777];
const AP_TIMES: [usize; NUM_APS] = [241, 337, 431];

static mut COMBS: [[DelayLine<2048>; NUM_COMBS]; MAX_CH] =
    [[DelayLine::new(); NUM_COMBS]; MAX_CH];
static mut APS: [[DelayLine<512>; NUM_APS]; MAX_CH] =
    [[DelayLine::new(); NUM_APS]; MAX_CH];
static mut PREDELAY_LINE: [DelayLine<4900>; MAX_CH] = [DelayLine::new(); MAX_CH];
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
        let predelay_ms = ctx.param(PREDELAY) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        let predelay_samples = (predelay_ms * 0.001 * sr).max(0.0) as usize;

        // Compute feedback gains for desired decay time per comb
        let mut comb_gains = [0.0_f64; NUM_COMBS];
        for c in 0..NUM_COMBS {
            if decay_s > 0.0 {
                comb_gains[c] =
                    10.0_f64.powf(-3.0 * COMB_TIMES[c] as f64 / (decay_s * sr));
            }
        }

        let damp = damping * 0.5;

        for ch in 0..ctx.channels() {
            for i in 0..ctx.frames() {
                // Predelay
                PREDELAY_LINE[ch].write(ctx.input(ch, i));
                let x = if predelay_samples > 0 {
                    PREDELAY_LINE[ch].tap(predelay_samples) as f64
                } else {
                    ctx.input(ch, i) as f64
                };

                // Parallel comb filters with damping
                let mut comb_sum = 0.0_f64;
                for c in 0..NUM_COMBS {
                    let comb_out = COMBS[ch][c].tap(COMB_TIMES[c]) as f64;

                    // One-pole lowpass damping in feedback
                    LP_STATE[ch][c] = LP_STATE[ch][c] * damp + comb_out * (1.0 - damp);

                    COMBS[ch][c]
                        .write((x + LP_STATE[ch][c] * comb_gains[c]) as f32);
                    comb_sum += comb_out;
                }

                comb_sum /= NUM_COMBS as f64;

                // Series allpass diffusers
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
    }
}
