// Synthwave Chorus — 80s synth chorus (Juno-60 style).
//
// The lush, wide chorus that defined 80s synth-pop. Models the Roland
// Juno-60's BBD chorus with warm filtering and three modulated voices.

use conjuredsp::*;
setup!();

params! {
    RATE = param(0.2, 2.0).unit("Hz").default(0.5),
    DEPTH_P = param(1.0, 15.0).unit("ms").default(5.0),
    WARMTH = param(0.0, 1.0).default(0.4),
    MIX = mix().default(0.5),
}

const MAX_DELAY: usize = 2048;

static mut DELAYS: [[DelayLine<MAX_DELAY>; 3]; MAX_CH] = [[DelayLine::new(); 3]; MAX_CH];
static mut LP: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut PHASES: [f64; 3] = [0.0, 0.33, 0.67];

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
        let depth_ms = ctx.param(DEPTH_P) as f64;
        let warmth = ctx.param(WARMTH) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        let two_pi = 2.0 * core::f64::consts::PI;

        let depth_samples = depth_ms * 0.001 * sr;
        let base_delay = depth_samples + 5.0;

        // BBD-style rolloff
        let lp_freq = 10000.0 - warmth * 6000.0;

        for ch in 0..ctx.channels() {
            LP[ch].set_coeffs(BiquadCoeffs::lowpass(lp_freq, 0.7, sr));
        }

        for i in 0..ctx.frames() {
            for ch in 0..ctx.channels() {
                let x = ctx.input(ch, i) as f64;

                let mut wet = 0.0;
                for v in 0..3 {
                    DELAYS[ch][v].write(x as f32);
                    let modulation = (two_pi * PHASES[v]).sin() * depth_samples;
                    let delay = base_delay + modulation;
                    let delay_clamped = if delay > 1.0 { delay } else { 1.0 };
                    wet += DELAYS[ch][v].read_cubic(delay_clamped) as f64;
                }
                wet /= 3.0;

                // BBD warmth
                wet = LP[ch].process_sample(wet);

                ctx.set_output(
                    ch,
                    i,
                    (x * (1.0 - wet_mix) + wet * wet_mix) as f32,
                );
            }

            for v in 0..3 {
                let voice_rate = rate * (0.9 + 0.2 * v as f64 / 2.0);
                PHASES[v] = (PHASES[v] + voice_rate / sr) % 1.0;
            }
        }
    }
}
