// Vocal Doubler — ADT (Automatic Double Tracking).
//
// Creates a realistic doubled vocal by adding a slightly delayed
// and detuned copy. The delay and detuning vary slightly over time
// to simulate a human re-performance (no two takes are identical).
// The spread control pans the double for stereo width. Invented
// at Abbey Road Studios for The Beatles — the original ADT effect
// used by John Lennon.
//
// Params:
//   depth:  Delay offset for the double (5-40 ms)
//   detune: Pitch variation amount (0-1)
//   spread: Stereo spread of the double (0 = center, 1 = wide)
//   mix:    Doubled signal level

use conjuredsp::*;
setup!();

const MAX_DELAY: usize = 4096;

params! {
    DEPTH = param(5.0, 40.0).unit("ms").default(15.0),
    DETUNE = param(0.0, 1.0).default(0.3),
    SPREAD = param(0.0, 1.0).default(0.7),
    MIX = mix().default(0.4),
}

static mut DELAYS: [DelayLine<MAX_DELAY>; MAX_CH] = [DelayLine::new(); MAX_CH];
static mut PHASE: f64 = 0.0;
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
    let two_pi = 2.0 * core::f64::consts::PI;

    unsafe {
        let depth_ms = ctx.param(DEPTH) as f64;
        let detune = ctx.param(DETUNE) as f64;
        let spread = ctx.param(SPREAD) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        let base_delay = depth_ms * 0.001 * sr;
        let mod_depth = detune * 3.0; // samples of pitch modulation

        let mut phase = PHASE;

        for i in 0..ctx.frames() {
            // Slow, irregular modulation (simulates human timing variation)
            let mut modulation = (two_pi * phase * 0.7).sin() * mod_depth;
            modulation += (two_pi * phase * 1.3).sin() * mod_depth * 0.5;
            modulation += (rng() - 0.5) * detune * 0.5;

            let mut delay_samples = base_delay + modulation;
            if delay_samples < 1.0 {
                delay_samples = 1.0;
            }

            for ch in 0..ctx.channels() {
                DELAYS[ch].write(ctx.input(ch, i));
                let doubled = DELAYS[ch].read_cubic(delay_samples) as f64;

                let out: f64;
                if ctx.channels() >= 2 && spread > 0.0 {
                    // Pan: original centered, double spread out
                    if ch == 0 {
                        out = ctx.input(ch, i) as f64 + doubled * wet_mix * (1.0 - spread * 0.5);
                    } else {
                        out = ctx.input(ch, i) as f64 + doubled * wet_mix * (1.0 + spread * 0.5);
                    }
                } else {
                    out = ctx.input(ch, i) as f64 + doubled * wet_mix;
                }
                ctx.set_output(ch, i, out as f32);
            }

            phase = (phase + 1.0 / sr) % 1.0;
        }

        PHASE = phase;
    }
}
