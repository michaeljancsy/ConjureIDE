// Pitch Glitch — random pitch-jumping effect.

use conjuredsp::*;
setup!();

const MAX_DELAY: usize = 8192;

params! {
    RATE = param(0.5, 20.0).unit("Hz").default(4.0),
    RANGE = param(1.0, 24.0).unit("st").default(12.0),
    CHANCE = param(0.0, 1.0).default(0.5),
    MIX = mix().default(0.5),
}

static mut DELAYS: [DelayLine<MAX_DELAY>; MAX_CH] = [DelayLine::new(); MAX_CH];
static mut PHASE: f64 = 0.0;
static mut CURRENT_PITCH: f64 = 1.0;
static mut RAMP: f64 = 0.0;
static mut RNG_STATE: u32 = 12345;

fn rng() -> f64 {
    unsafe {
        RNG_STATE = RNG_STATE.wrapping_mul(1664525).wrapping_add(1013904223);
        RNG_STATE as f64 / 4294967296.0
    }
}

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
        let pitch_range = ctx.param(RANGE) as f64;
        let chance = ctx.param(CHANCE) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        let base_delay = 200.0;

        for i in 0..ctx.frames() {
            let old_phase = PHASE;
            PHASE = (PHASE + rate / sr) % 1.0;

            if PHASE < old_phase {
                if rng() < chance {
                    let st = rng() * 2.0 * pitch_range - pitch_range;
                    CURRENT_PITCH = 2.0_f64.powf(st / 12.0);
                } else {
                    CURRENT_PITCH = 1.0;
                }
            }

            RAMP = (RAMP + (1.0 - CURRENT_PITCH)) % MAX_DELAY as f64;
            let delay = (base_delay + RAMP).max(1.0) % MAX_DELAY as f64;

            for c in 0..ctx.channels() {
                DELAYS[c].write(ctx.input(c, i));
                let pitched = DELAYS[c].read_cubic(delay) as f64;
                ctx.set_output(c, i, (ctx.input(c, i) as f64 * (1.0 - wet_mix) + pitched * wet_mix) as f32);
            }
        }
    }
}
