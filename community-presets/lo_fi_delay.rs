// Lo-Fi Delay — degraded, deteriorating echoes.
//
// Each repeat is progressively degraded: bit-crushed, sample-rate
// reduced, and filtered. Repeats become increasingly distorted and
// unrecognizable, like a tape being recorded over and over.

use conjuredsp::*;
setup!();

params! {
    TIME = time_ms().min(50.0).max(600.0).default(250.0),
    FEEDBACK = param(0.0, 0.95).default(0.5),
    DEGRADE = param(0.0, 1.0).default(0.6),
    MIX = mix().default(0.5),
}

const MAX_DELAY: usize = 64000;

static mut DELAYS: [DelayLine<MAX_DELAY>; MAX_CH] = [DelayLine::new(); MAX_CH];
static mut HELD: [f64; MAX_CH] = [0.0; MAX_CH];
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
        let delay_ms = ctx.param(TIME) as f64;
        let feedback = ctx.param(FEEDBACK) as f64;
        let degrade = ctx.param(DEGRADE) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        let mut delay_samples = delay_ms * 0.001 * sr;
        if delay_samples < 1.0 {
            delay_samples = 1.0;
        }

        // Degradation settings
        let mut bit_depth = (16.0 - degrade * 12.0) as i32;
        if bit_depth < 2 {
            bit_depth = 2;
        }
        let levels = (1_i64 << bit_depth) as f64;
        let mut downsample = (1.0 + degrade * 8.0) as usize;
        if downsample < 1 {
            downsample = 1;
        }

        for i in 0..ctx.frames() {
            for ch in 0..ctx.channels() {
                let mut delayed = DELAYS[ch].read(delay_samples) as f64;

                // Bit crush the feedback
                delayed = (delayed * levels).round() / levels;

                // Sample rate reduce
                if i % downsample == 0 {
                    HELD[ch] = delayed;
                }
                delayed = HELD[ch];

                // Add tiny noise
                delayed += (rng() - 0.5) * degrade * 0.01;

                DELAYS[ch].write((ctx.input(ch, i) as f64 + delayed * feedback) as f32);

                ctx.set_output(
                    ch,
                    i,
                    (ctx.input(ch, i) as f64 * (1.0 - wet_mix) + delayed * wet_mix) as f32,
                );
            }
        }
    }
}
