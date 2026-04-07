// Wow & Flutter — tape/vinyl speed imperfections.
//
// Wow is slow pitch wobble (from tape hub irregularities or warped
// vinyl). Flutter is faster pitch jitter (from capstan/motor
// irregularities). Together they create the nostalgic imperfection
// of analog playback.

use conjuredsp::*;
setup!();

params! {
    WOW = param(0.0, 1.0).default(0.3),
    FLUTTER = param(0.0, 1.0).default(0.4),
    NOISE = param(0.0, 1.0).default(0.1),
}

static mut RNG_STATE: u32 = 12345;

fn rng() -> f64 {
    unsafe {
        RNG_STATE = RNG_STATE.wrapping_mul(1664525).wrapping_add(1013904223);
        RNG_STATE as f64 / 4294967296.0
    }
}

static mut DELAYS: [DelayLine<2048>; MAX_CH] = [DelayLine::new(); MAX_CH];
static mut WOW_PHASE: f64 = 0.0;
static mut FLUTTER_PHASE: f64 = 0.0;

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
        let wow = ctx.param(WOW) as f64;
        let flutter = ctx.param(FLUTTER) as f64;
        let noise = ctx.param(NOISE) as f64;

        let two_pi = 2.0 * core::f64::consts::PI;

        let wow_rate = 0.5;
        let wow_depth = wow * 5.0;

        let flutter_rate = 6.0;
        let flutter_depth = flutter * 2.0;

        let base_delay = 20.0;

        for i in 0..ctx.frames() {
            let wow_mod = (two_pi * WOW_PHASE).sin() * wow_depth;
            let flutter_mod = (two_pi * FLUTTER_PHASE).sin() * flutter_depth;
            let noise_mod = (rng() * 2.0 - 1.0) * noise * 1.0;

            let mut delay = base_delay + wow_mod + flutter_mod + noise_mod;
            if delay < 1.0 {
                delay = 1.0;
            }

            for c in 0..ctx.channels() {
                DELAYS[c].write(ctx.input(c, i) as f64);
                ctx.set_output(c, i, DELAYS[c].read_cubic(delay) as f32);
            }

            WOW_PHASE = (WOW_PHASE + wow_rate / sr) % 1.0;
            FLUTTER_PHASE = (FLUTTER_PHASE + flutter_rate / sr) % 1.0;
        }
    }
}
