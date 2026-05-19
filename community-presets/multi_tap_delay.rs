// Multi-Tap Delay — 4-tap rhythmic delay.
//
// Creates complex rhythmic echo patterns by reading the delay line
// at 4 different positions. Tap 1 is the base time; taps 2-4 are
// multiples of that time.

use conjuredsp::*;
setup!();

params! {
    TIME = time_ms().min(50.0).max(500.0).default(200.0),
    TAP2 = param(0.25, 2.0).unit("x").default(0.5),
    TAP3 = param(0.25, 2.0).unit("x").default(0.75),
    TAP4 = param(0.25, 2.0).unit("x").default(1.5),
    FEEDBACK = param(0.0, 0.9).default(0.3),
    MIX = mix().default(0.5),
}

const MAX_DELAY: usize = 96000;

static mut DELAYS: [DelayLine<MAX_DELAY>; MAX_CH] = [DelayLine::new(); MAX_CH];

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
        let base_ms = ctx.param(TIME) as f64;
        let tap2_ratio = ctx.param(TAP2) as f64;
        let tap3_ratio = ctx.param(TAP3) as f64;
        let tap4_ratio = ctx.param(TAP4) as f64;
        let feedback = ctx.param(FEEDBACK) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        let mut tap_times = [
            base_ms * 0.001 * sr,
            base_ms * tap2_ratio * 0.001 * sr,
            base_ms * tap3_ratio * 0.001 * sr,
            base_ms * tap4_ratio * 0.001 * sr,
        ];

        // Clamp taps
        for t in tap_times.iter_mut() {
            if *t < 1.0 {
                *t = 1.0;
            }
            if *t > (MAX_DELAY - 1) as f64 {
                *t = (MAX_DELAY - 1) as f64;
            }
        }

        // Tap levels (later taps slightly quieter)
        let levels: [f64; 4] = [1.0, 0.8, 0.6, 0.4];

        for i in 0..ctx.frames() {
            for ch in 0..ctx.channels() {
                // Sum all taps
                let mut wet = 0.0;
                for t in 0..4 {
                    wet += DELAYS[ch].tap(tap_times[t] as usize) as f64 * levels[t];
                }

                wet *= 0.25; // normalize

                DELAYS[ch].write((ctx.input(ch, i) as f64 + wet * feedback) as f32);

                ctx.set_output(
                    ch,
                    i,
                    (ctx.input(ch, i) as f64 * (1.0 - wet_mix) + wet * wet_mix) as f32,
                );
            }
        }
    }
}
