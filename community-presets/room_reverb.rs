// Room Reverb — small room / studio ambience.
//
// Simulates the natural reflections of a small to medium room.
// Short decay, moderate density, with early reflections that give
// a sense of physical space.

use conjuredsp::*;
setup!();

params! {
    SIZE = param(0.1, 1.0).default(0.4),
    DAMPING = param(0.0, 1.0).default(0.5),
    PREDELAY = param(0.0, 30.0).unit("ms").default(5.0),
    MIX = mix().default(0.25),
}

const NUM_COMBS: usize = 6;
const NUM_APS: usize = 3;
const BASE_COMB: [usize; NUM_COMBS] = [743, 877, 1013, 1151, 1283, 1409];
const BASE_AP: [usize; NUM_APS] = [167, 229, 307];

static mut COMBS: [[DelayLine<4096>; NUM_COMBS]; MAX_CH] =
    [[DelayLine::new(); NUM_COMBS]; MAX_CH];
static mut APS: [[DelayLine<1024>; NUM_APS]; MAX_CH] =
    [[DelayLine::new(); NUM_APS]; MAX_CH];
static mut PRE: [DelayLine<4096>; MAX_CH] = [DelayLine::new(); MAX_CH];
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
        let size = ctx.param(SIZE) as f64;
        let damping = ctx.param(DAMPING) as f64;
        let predelay_ms = ctx.param(PREDELAY) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        let predelay_samples = (predelay_ms * 0.001 * sr).max(0.0) as usize;

        // Scale comb times by size
        let mut comb_times = [0_usize; NUM_COMBS];
        for c in 0..NUM_COMBS {
            comb_times[c] = (BASE_COMB[c] as f64 * (0.5 + size * 0.8)) as usize;
        }
        let mut ap_times = [0_usize; NUM_APS];
        for a in 0..NUM_APS {
            ap_times[a] = (BASE_AP[a] as f64 * (0.5 + size * 0.5)) as usize;
        }

        // Short decay for rooms (0.2 to 1.5 seconds based on size)
        let decay_s = 0.2 + size * 1.3;
        let damp = damping * 0.6;

        let mut comb_gains = [0.0_f64; NUM_COMBS];
        for c in 0..NUM_COMBS {
            comb_gains[c] =
                10.0_f64.powf(-3.0 * comb_times[c] as f64 / (decay_s * sr));
        }

        for ch in 0..ctx.channels() {
            for i in 0..ctx.frames() {
                PRE[ch].write(ctx.input(ch, i));
                let x = if predelay_samples > 0 {
                    PRE[ch].tap(predelay_samples) as f64
                } else {
                    ctx.input(ch, i) as f64
                };

                let mut comb_sum = 0.0_f64;
                for c in 0..NUM_COMBS {
                    let ct = comb_times[c].min(4095);
                    let comb_out = COMBS[ch][c].tap(ct) as f64;
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
                    let at = ap_times[a].min(1023);
                    let ap_out = APS[ch][a].tap(at) as f64;
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
