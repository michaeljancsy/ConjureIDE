// Data Corrupt — audio-as-data corruption simulation.
//
// Simulates what happens when audio data gets corrupted in
// transmission: dropped samples, stuck values, and bit errors.

use conjuredsp::*;
setup!();

params! {
    SKIP = param(0.0, 0.1).default(0.02),
    REPEAT = param(0.0, 0.1).default(0.03),
    NOISE = param(0.0, 0.5).default(0.1),
    MIX = mix().default(0.7),
}

static mut PREV_SAMPLE: [f64; MAX_CH] = [0.0; MAX_CH];
static mut SKIP_COUNTER: [usize; MAX_CH] = [0; MAX_CH];
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

    unsafe {
        let skip_prob = ctx.param(SKIP) as f64;
        let repeat_prob = ctx.param(REPEAT) as f64;
        let noise = ctx.param(NOISE) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        for ch in 0..ctx.channels() {
            let mut prev = PREV_SAMPLE[ch];

            for i in 0..ctx.frames() {
                let x = ctx.input(ch, i) as f64;
                let mut y = x;

                // Skip: drop sample, hold previous value
                if rng() < skip_prob {
                    y = prev;
                }
                // Repeat: get stuck on current value
                else if rng() < repeat_prob {
                    SKIP_COUNTER[ch] = 2 + (rng() * 19.0) as usize;
                }

                if SKIP_COUNTER[ch] > 0 {
                    y = prev;
                    SKIP_COUNTER[ch] -= 1;
                } else {
                    prev = y;
                }

                // Data error noise
                if rng() < noise * 0.1 {
                    y += (rng() - 0.5) * noise * 2.0;
                }

                ctx.set_output(ch, i, (x * (1.0 - wet_mix) + y * wet_mix) as f32);
            }

            PREV_SAMPLE[ch] = prev;
        }
    }
}
