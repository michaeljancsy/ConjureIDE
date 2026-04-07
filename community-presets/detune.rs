// Detune — subtle pitch detuning for stereo width.

use conjuredsp::*;
setup!();

const MAX_DELAY: usize = 4096;

params! {
    CENTS = param(1.0, 50.0).unit("ct").default(10.0),
    MIX = mix().default(0.5),
}

static mut DELAYS: [DelayLine<MAX_DELAY>; MAX_CH] = [DelayLine::new(); MAX_CH];
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
    let two_pi = 2.0 * core::f64::consts::PI;

    unsafe {
        let cents = ctx.param(CENTS) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        let mod_rate = cents * 0.01;
        let mod_depth = cents * 0.5;
        let base_delay = 100.0;

        for i in 0..ctx.frames() {
            let modv = (two_pi * PHASE).sin() * mod_depth;
            let delay = (base_delay + modv).max(1.0);

            for c in 0..ctx.channels() {
                DELAYS[c].write(ctx.input(c, i));
                let detuned = DELAYS[c].read_cubic(delay) as f64;

                let out = if ctx.channels() >= 2 {
                    if c == 0 {
                        ctx.input(c, i) as f64 * (1.0 - wet_mix * 0.3) + detuned * wet_mix * 0.3
                    } else {
                        ctx.input(c, i) as f64 * (1.0 - wet_mix * 0.7) + detuned * wet_mix * 0.7
                    }
                } else {
                    ctx.input(c, i) as f64 * (1.0 - wet_mix) + detuned * wet_mix
                };

                ctx.set_output(c, i, out as f32);
            }

            PHASE = (PHASE + mod_rate / sr) % 1.0;
        }
    }
}
