// Through-Zero Flanger — the jet plane flanging effect.
//
// Unlike conventional flanging (where one signal is always delayed),
// through-zero flanging delays BOTH the dry and wet signals so the
// modulated delay sweeps through zero — creating total cancellation
// and the iconic "jet plane" whoosh.

use conjuredsp::*;
setup!();

params! {
    RATE = param(0.05, 2.0).unit("Hz").default(0.2),
    DEPTH = param(0.0, 1.0).default(0.8),
    FEEDBACK = param(-0.95, 0.95).default(0.5),
    MIX = mix().default(0.7),
}

static mut DELAYS_WET: [DelayLine<4096>; MAX_CH] = [DelayLine::new(); MAX_CH];
static mut DELAYS_DRY: [DelayLine<4096>; MAX_CH] = [DelayLine::new(); MAX_CH];
static mut PHASE: f64 = 0.0;

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
        let rate = ctx.param(RATE) as f64;
        let depth = ctx.param(DEPTH) as f64;
        let feedback = ctx.param(FEEDBACK) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        let two_pi = 2.0 * core::f64::consts::PI;

        let max_sweep = depth * 100.0;
        let center = max_sweep + 5.0;

        for i in 0..ctx.frames() {
            let modulation = (two_pi * PHASE).sin() * max_sweep;

            // Through-zero: dry gets (center + mod), wet gets (center - mod)
            let dry_delay = center + modulation;
            let wet_delay = center - modulation;

            for c in 0..ctx.channels() {
                let x = ctx.input(c, i) as f64;

                let wet_out = DELAYS_WET[c].read(if wet_delay > 1.0 { wet_delay } else { 1.0 });

                DELAYS_WET[c].write(x + wet_out * feedback);
                DELAYS_DRY[c].write(x);

                let dry_out = DELAYS_DRY[c].read(if dry_delay > 1.0 { dry_delay } else { 1.0 });

                ctx.set_output(c, i, (dry_out * (1.0 - wet_mix) + wet_out * wet_mix) as f32);
            }

            PHASE = (PHASE + rate / sr) % 1.0;
        }
    }
}
