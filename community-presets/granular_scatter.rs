// Granular Scatter — grain-based audio scattering.
//
// Captures audio into a buffer and plays back small "grains"
// at random positions.

use conjuredsp::*;
setup!();

params! {
    DENSITY = param(1.0, 30.0).unit("Hz").default(10.0),
    GRAIN_SIZE = param(5.0, 100.0).unit("ms").default(30.0),
    SCATTER = param(0.0, 1.0).default(0.5),
    MIX = mix().default(0.5),
}

const MAX_BUF: usize = 96000;
const MAX_GRAINS: usize = 20;

static mut BUFFER: [[f32; MAX_BUF]; MAX_CH] = [[0.0; MAX_BUF]; MAX_CH];
static mut WRITE_POS: usize = 0;

// Grain state: [start, pos, len] per grain
static mut GRAIN_START: [usize; MAX_GRAINS] = [0; MAX_GRAINS];
static mut GRAIN_POS: [usize; MAX_GRAINS] = [0; MAX_GRAINS];
static mut GRAIN_LEN: [usize; MAX_GRAINS] = [0; MAX_GRAINS];
static mut NUM_GRAINS: usize = 0;

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
        let density = ctx.param(DENSITY) as f64;
        let grain_ms = ctx.param(GRAIN_SIZE) as f64;
        let scatter = ctx.param(SCATTER) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        let grain_samples = (grain_ms * 0.001 * sr) as usize;

        // Write input to circular buffer
        for i in 0..ctx.frames() {
            for ch in 0..ctx.channels() {
                BUFFER[ch][WRITE_POS] = ctx.input(ch, i);
            }
            WRITE_POS = (WRITE_POS + 1) % MAX_BUF;
        }

        // Spawn new grains
        let grain_interval = if density > 0.0 { (sr / density) as usize } else { sr as usize };
        let spawn_count = (ctx.frames() / grain_interval).max(1);
        let fc = ctx.frames();

        for _ in 0..spawn_count {
            if rng() < density * fc as f64 / sr {
                if NUM_GRAINS < MAX_GRAINS {
                    let max_offset = (scatter * MAX_BUF as f64 * 0.5) as usize;
                    let offset = (rng() * max_offset.max(1) as f64) as usize;
                    let start = (WRITE_POS + MAX_BUF - grain_samples - offset) % MAX_BUF;
                    GRAIN_START[NUM_GRAINS] = start;
                    GRAIN_POS[NUM_GRAINS] = 0;
                    GRAIN_LEN[NUM_GRAINS] = grain_samples;
                    NUM_GRAINS += 1;
                }
            }
        }

        // Initialize output with dry signal
        for ch in 0..ctx.channels() {
            for i in 0..ctx.frames() {
                ctx.set_output(ch, i, (ctx.input(ch, i) as f64 * (1.0 - wet_mix)) as f32);
            }
        }

        // Mix grains into output
        let two_pi = 2.0 * core::f64::consts::PI;
        let mut active_count = 0usize;

        for g in 0..NUM_GRAINS {
            for i in 0..ctx.frames() {
                if GRAIN_POS[g] < GRAIN_LEN[g] {
                    // Hanning window
                    let t = GRAIN_POS[g] as f64 / GRAIN_LEN[g] as f64;
                    let window = 0.5 * (1.0 - (two_pi * t).cos());

                    let read_idx = (GRAIN_START[g] + GRAIN_POS[g]) % MAX_BUF;
                    for ch in 0..ctx.channels() {
                        let cur = ctx.output(ch, i) as f64;
                        let grain_val = BUFFER[ch][read_idx] as f64 * window * wet_mix * 0.3;
                        ctx.set_output(ch, i, (cur + grain_val) as f32);
                    }
                    GRAIN_POS[g] += 1;
                }
            }

            if GRAIN_POS[g] < GRAIN_LEN[g] {
                // Keep this grain alive
                if active_count != g {
                    GRAIN_START[active_count] = GRAIN_START[g];
                    GRAIN_POS[active_count] = GRAIN_POS[g];
                    GRAIN_LEN[active_count] = GRAIN_LEN[g];
                }
                active_count += 1;
            }
        }

        NUM_GRAINS = active_count;
    }
}
