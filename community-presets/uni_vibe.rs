// Uni-Vibe — Univox Uni-Vibe photocell modulator.
//
// Neither chorus nor phaser — a unique effect using photocells and
// a light bulb to create uneven phase shifts across 4 stages.
// Iconic for Hendrix, Robin Trower, and David Gilmour tones.

use conjuredsp::*;
setup!();

params! {
    MODE = choice(&["Chorus", "Vibrato"]).default(0.0),
    SPEED = param(0.5, 10.0).unit("Hz").default(3.0),
    DEPTH = param(0.0, 1.0).default(0.7),
    MIX = mix().default(0.7),
}

static mut PHASE: f64 = 0.0;
// 4 allpass stages per channel
static mut AP: [[Biquad; 4]; MAX_CH] = [[Biquad::new(); 4]; MAX_CH];

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
        let mode = ctx.param(MODE) as i32;
        let speed = ctx.param(SPEED) as f64;
        let depth = ctx.param(DEPTH) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        let two_pi = 2.0 * core::f64::consts::PI;
        let base_freqs: [f64; 4] = [200.0, 500.0, 1200.0, 3500.0];

        for i in 0..ctx.frames() {
            let lfo_raw = (two_pi * PHASE).sin();
            // Asymmetric — slower rise, faster fall (lamp thermal lag)
            let lfo = lfo_raw * 0.7 + 0.3 * lfo_raw * lfo_raw.abs();
            let lfo_val = 0.5 + 0.5 * lfo * depth;

            for c in 0..ctx.channels() {
                let x = ctx.input(c, i) as f64;
                let mut y = x;

                for stage in 0..4 {
                    let mut sweep_freq = base_freqs[stage] * (0.5 + lfo_val * 2.0);
                    if sweep_freq > sr * 0.45 {
                        sweep_freq = sr * 0.45;
                    }
                    let coeffs = BiquadCoeffs::allpass(sweep_freq, 0.5, sr);
                    AP[c][stage].set_coeffs(coeffs);
                    y = AP[c][stage].process(y);
                }

                if mode == 1 {
                    // Vibrato
                    ctx.set_output(c, i, y as f32);
                } else {
                    // Chorus
                    ctx.set_output(c, i, (x * (1.0 - wet_mix) + y * wet_mix) as f32);
                }
            }

            PHASE = (PHASE + speed / sr) % 1.0;
        }
    }
}
