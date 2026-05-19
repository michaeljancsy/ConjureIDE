// Vocal Thickener — chorus + saturation for rich vocals.
//
// Combines subtle chorus (for body), gentle saturation (for warmth),
// and a high-shelf "air" boost (for presence) — the three classic
// mixing tricks for thick, professional vocals in one preset.
// Designed to make thin or dry vocal takes sound polished and
// full. Essential for pop, R&B, and any vocal-forward production.
//
// Params:
//   thickness: Chorus depth for vocal body (0-1)
//   warmth:    Saturation for harmonics (0-1)
//   air:       High-frequency presence boost (0-1)
//   mix:       Effect blend

use conjuredsp::*;
setup!();

const MAX_DELAY: usize = 2048;

params! {
    THICKNESS = param(0.0, 1.0).default(0.5),
    WARMTH = param(0.0, 1.0).default(0.4),
    AIR = param(0.0, 1.0).default(0.3),
    MIX = mix().default(0.5),
}

static mut DELAYS: [DelayLine<MAX_DELAY>; MAX_CH] = [DelayLine::new(); MAX_CH];
static mut HS: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut PHASE: f64 = 0.0;

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
        let thickness = ctx.param(THICKNESS) as f64;
        let warmth = ctx.param(WARMTH) as f64;
        let air = ctx.param(AIR) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        let hs_coeffs = BiquadCoeffs::highshelf(8000.0, 0.7, air * 6.0, sr);
        for ch in 0..ctx.channels() {
            HS[ch].set_coeffs(hs_coeffs);
        }

        let mut phase = PHASE;

        for i in 0..ctx.frames() {
            let modulation = (two_pi * phase).sin() * thickness * 3.0;
            let mut delay = 8.0 + modulation;
            if delay < 1.0 {
                delay = 1.0;
            }

            for ch in 0..ctx.channels() {
                let x = ctx.input(ch, i) as f64;

                // Chorus for thickness
                DELAYS[ch].write(ctx.input(ch, i));
                let chorus = DELAYS[ch].read_cubic(delay) as f64;

                // Blend dry and chorus
                let mut y = x * (1.0 - wet_mix * 0.5) + chorus * wet_mix * 0.5;

                // Warmth via gentle saturation
                if warmth > 0.0 {
                    let drive = 1.0 + warmth * 3.0;
                    y = (y * drive).tanh() / drive * (drive * 0.7);
                }

                // Air boost
                y = HS[ch].process_sample(y);

                ctx.set_output(ch, i, (x * (1.0 - wet_mix) + y * wet_mix) as f32);
            }

            phase = (phase + 0.7 / sr) % 1.0;
        }

        PHASE = phase;
    }
}
