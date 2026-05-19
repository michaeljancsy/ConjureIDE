// Vinyl Simulator — vintage record player character.
//
// Adds vinyl record imperfections: crackle, surface hiss, wow,
// and frequency rolloff.

use conjuredsp::*;
setup!();

params! {
    CRACKLE = param(0.0, 1.0).default(0.3),
    HISS = param(0.0, 0.05).default(0.005),
    WARP = param(0.0, 1.0).default(0.2),
    AGE = param(0.0, 1.0).default(0.5),
}

static mut LP: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut HP: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut WARP_PHASE: f64 = 0.0;
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
        let crackle = ctx.param(CRACKLE) as f64;
        let hiss = ctx.param(HISS) as f64;
        let warp = ctx.param(WARP) as f64;
        let age = ctx.param(AGE) as f64;

        let two_pi = 2.0 * core::f64::consts::PI;

        // Age controls bandwidth
        let lp_freq = 16000.0 - age * 10000.0;
        let hp_freq = 30.0 + age * 70.0;

        for ch in 0..ctx.channels() {
            LP[ch].set_coeffs(BiquadCoeffs::lowpass(lp_freq, 0.7, sr));
            HP[ch].set_coeffs(BiquadCoeffs::highpass(hp_freq, 0.7, sr));
        }

        for i in 0..ctx.frames() {
            // Crackle: random pops
            let mut pop = 0.0;
            if crackle > 0.0 {
                if rng() < crackle * 0.002 {
                    pop = (rng() - 0.3) * crackle * 0.5;
                }
            }

            // Surface hiss
            let noise = (rng() - 0.5) * hiss * 2.0;

            // Warp / wow
            let wow_mod = (two_pi * WARP_PHASE).sin() * warp * 0.002;
            WARP_PHASE = (WARP_PHASE + 0.5 / sr) % 1.0;

            for ch in 0..ctx.channels() {
                let mut x = ctx.input(ch, i) as f64;

                // Apply wow as slight level modulation
                x *= 1.0 + wow_mod;

                // Age filtering
                x = LP[ch].process_sample(x);
                x = HP[ch].process_sample(x);

                // Add artifacts
                x += pop + noise;

                ctx.set_output(ch, i, x as f32);
            }
        }
    }
}
