// Gated Reverb — 80s drum reverb.
//
// A dense reverb that cuts off abruptly after a set time, creating
// the explosive, punchy reverb sound that defined 80s drums.

use conjuredsp::*;
setup!();

params! {
    LENGTH = time_ms().min(50.0).max(500.0).default(200.0),
    DENSITY = param(0.0, 1.0).default(0.7),
    MIX = mix().default(0.5),
}

const NUM_COMBS: usize = 4;
const NUM_APS: usize = 2;
const COMB_TIMES: [usize; NUM_COMBS] = [997, 1153, 1327, 1489];
const AP_TIMES: [usize; NUM_APS] = [211, 317];

static mut COMBS: [[DelayLine<2048>; NUM_COMBS]; MAX_CH] =
    [[DelayLine::new(); NUM_COMBS]; MAX_CH];
static mut APS: [[DelayLine<512>; NUM_APS]; MAX_CH] =
    [[DelayLine::new(); NUM_APS]; MAX_CH];
static mut GATE_ENV: f64 = 0.0;
static mut GATE_COUNTER: i32 = 0;

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
        let length_ms = ctx.param(LENGTH) as f64;
        let density = ctx.param(DENSITY) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        let gate_samples = (length_ms * 0.001 * sr) as i32;
        let feedback = 0.5 + density * 0.4;
        let threshold = 0.05_f64;

        for i in 0..ctx.frames() {
            // Detect transients to trigger gate
            let mut peak = 0.0_f64;
            for ch in 0..ctx.channels() {
                let v = (ctx.input(ch, i) as f64).abs();
                if v > peak {
                    peak = v;
                }
            }

            if peak > threshold {
                GATE_COUNTER = gate_samples;
                GATE_ENV = 1.0;
            }

            if GATE_COUNTER > 0 {
                GATE_COUNTER -= 1;
            } else {
                // Sharp gate cutoff
                GATE_ENV *= 0.95;
                if GATE_ENV < 0.001 {
                    GATE_ENV = 0.0;
                }
            }

            for ch in 0..ctx.channels() {
                let x = ctx.input(ch, i) as f64;

                // Dense reverb via parallel combs
                let mut comb_sum = 0.0_f64;
                for c in 0..NUM_COMBS {
                    let comb_out = COMBS[ch][c].tap(COMB_TIMES[c]) as f64;
                    COMBS[ch][c].write(
                        (x + comb_out * feedback * GATE_ENV) as f32,
                    );
                    comb_sum += comb_out;
                }

                comb_sum /= NUM_COMBS as f64;

                // Allpass diffusion
                let mut y = comb_sum;
                for a in 0..NUM_APS {
                    let ap_out = APS[ch][a].tap(AP_TIMES[a]) as f64;
                    let ap_in = y - 0.5 * ap_out;
                    APS[ch][a].write(ap_in as f32);
                    y = ap_out + 0.5 * ap_in;
                }

                y *= GATE_ENV;

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
