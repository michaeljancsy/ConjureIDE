// Dimension Chorus — Roland Dimension D inspired.
//
// The legendary Dimension D had just 4 buttons — no knobs. Each mode
// is a carefully voiced combination of delay time, modulation depth,
// and rate. Mode I is subtle, Mode IV is extreme.

use conjuredsp::*;
setup!();

params! {
    MODE = choice(&["I", "II", "III", "IV"]).default(1.0),
}

// 3 voices per channel
static mut DELAYS: [[DelayLine<2048>; 3]; MAX_CH] = [[DelayLine::new(); 3]; MAX_CH];
static mut PHASES: [f64; 3] = [0.0; 3];

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
        let mode = ctx.param(MODE) as usize;

        let two_pi = 2.0 * core::f64::consts::PI;

        // Each mode has specific settings (base_delay_ms, depth_ms, rate_hz)
        let mode_base_ms: [f64; 4] = [3.0, 5.0, 7.0, 10.0];
        let mode_depth_ms: [f64; 4] = [0.3, 0.8, 1.5, 3.0];
        let mode_rate_hz: [f64; 4] = [0.5, 0.7, 1.0, 0.4];

        let idx = if mode < 4 { mode } else { 3 };
        let base_ms = mode_base_ms[idx];
        let depth_ms = mode_depth_ms[idx];
        let rate = mode_rate_hz[idx];

        let base_samples = base_ms * 0.001 * sr;
        let depth_samples = depth_ms * 0.001 * sr;

        // 3 voices with carefully offset phases
        let phase_offsets: [f64; 3] = [0.0, two_pi / 3.0, 2.0 * two_pi / 3.0];
        let voice_rates: [f64; 3] = [rate, rate * 1.07, rate * 0.93];

        for i in 0..ctx.frames() {
            for c in 0..ctx.channels() {
                let x = ctx.input(c, i) as f64;

                let mut wet = 0.0;
                for v in 0..3 {
                    DELAYS[c][v].write(x);
                    let modulation = (two_pi * PHASES[v] + phase_offsets[v]).sin();
                    let delay = base_samples + modulation * depth_samples;
                    let delay_clamped = if delay > 1.0 { delay } else { 1.0 };
                    wet += DELAYS[c][v].read_cubic(delay_clamped);
                }

                wet /= 3.0;

                // Dimension D uses roughly 50/50 dry/wet
                ctx.set_output(c, i, (x * 0.5 + wet * 0.5) as f32);
            }

            for v in 0..3 {
                PHASES[v] = (PHASES[v] + voice_rates[v] / sr) % 1.0;
            }
        }
    }
}
