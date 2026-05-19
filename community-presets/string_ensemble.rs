// String Ensemble — multi-voice chorus (Roland Dimension D style).
//
// Creates multiple detuned copies using independently modulated delay
// lines. Each voice has a different LFO rate and phase, producing a
// rich, animated ensemble effect without metallic artifacts.

use conjuredsp::*;
setup!();

params! {
    VOICES = param(2.0, 6.0).default(3.0),
    RATE = param(0.2, 2.0).unit("Hz").default(0.6),
    DEPTH = param(0.5, 10.0).unit("ms").default(3.0),
    MIX = mix().default(0.6),
}

// 6 delay lines per channel (max voices)
static mut DELAYS: [[DelayLine<2048>; 6]; MAX_CH] = [[DelayLine::new(); 6]; MAX_CH];
static mut PHASES: [f64; 6] = [0.05, 0.18, 0.31, 0.44, 0.57, 0.70];

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
        let n_voices = ctx.param(VOICES) as i32;
        let rate = ctx.param(RATE) as f64;
        let depth_ms = ctx.param(DEPTH) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        let two_pi = 2.0 * core::f64::consts::PI;
        let depth_samples = depth_ms * 0.001 * sr;
        let base_delay = depth_samples + 5.0;

        for i in 0..ctx.frames() {
            for c in 0..ctx.channels() {
                let x = ctx.input(c, i) as f64;

                // Write to all delay lines
                for v in 0..n_voices as usize {
                    DELAYS[c][v].write(x);
                }

                // Sum modulated reads
                let mut wet = 0.0;
                for v in 0..n_voices as usize {
                    let denom = if n_voices > 1 { (n_voices - 1) as f64 } else { 1.0 };
                    let voice_rate = rate * (0.8 + 0.4 * v as f64 / denom);
                    let _ = voice_rate; // rate used for phase advance below
                    let modulation = (two_pi * PHASES[v]).sin() * depth_samples;
                    let delay = base_delay + modulation;
                    let delay_clamped = if delay > 1.0 { delay } else { 1.0 };
                    wet += DELAYS[c][v].read_cubic(delay_clamped);
                }

                wet /= n_voices as f64;

                ctx.set_output(c, i, (x * (1.0 - wet_mix) + wet * wet_mix) as f32);
            }

            // Advance all phases
            for v in 0..n_voices as usize {
                let denom = if n_voices > 1 { (n_voices - 1) as f64 } else { 1.0 };
                let voice_rate = rate * (0.8 + 0.4 * v as f64 / denom);
                PHASES[v] = (PHASES[v] + voice_rate / sr) % 1.0;
            }
        }
    }
}
