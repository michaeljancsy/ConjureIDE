// Rain Texture -- rain-like noise overlay.
//
// Adds filtered noise that sounds like rain, from light drizzle
// to heavy downpour. Layer over any music for lo-fi ambience.

use conjuredsp::*;
setup!();

params! {
    DENSITY = param(0.0, 1.0).default(0.5),
    SIZE = param(0.0, 1.0).default(0.5),
    DAMPING = param(0.0, 1.0).default(0.4),
    MIX = mix().default(0.3),
}

static mut RNG_STATE: u32 = 12345;

fn rng() -> f64 {
    unsafe {
        RNG_STATE = RNG_STATE.wrapping_mul(1664525).wrapping_add(1013904223);
        RNG_STATE as f64 / 4294967296.0
    }
}

static mut HP: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut LP: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];

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
        let size = ctx.param(SIZE) as f64;
        let damping = ctx.param(DAMPING) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        let hp_freq = 200.0 + (1.0 - size) * 2000.0;
        let lp_freq = 12000.0 - damping * 8000.0;

        for ch in 0..ctx.channels() {
            HP[ch].set_coeffs(BiquadCoeffs::highpass(hp_freq, 0.7, sr));
            LP[ch].set_coeffs(BiquadCoeffs::lowpass(lp_freq, 0.7, sr));
        }

        for i in 0..ctx.frames() {
            // Generate rain noise: white noise with random "drops"
            let mut base_noise = (rng() - 0.5) * density * 0.3;

            // Add occasional larger drops
            if rng() < density * 0.01 {
                base_noise += (rng() - 0.5) * size * 0.5;
            }

            for ch in 0..ctx.channels() {
                // Slightly different noise per channel for stereo
                let noise_val = base_noise + (rng() - 0.5) * density * 0.05;

                // Shape the rain noise
                let noise_val =
                    HP[ch].process_sample(noise_val as f32) as f64;
                let noise_val =
                    LP[ch].process_sample(noise_val as f32) as f64;

                let inp = ctx.input(ch, i) as f64;
                ctx.set_output(
                    ch,
                    i,
                    (inp + noise_val * wet_mix) as f32,
                );
            }
        }
    }
}
