// Tape Echo — Roland Space Echo / Echoplex inspired.
//
// Models the warm, decaying echoes of vintage tape delay units.
// Each repeat passes through a lowpass filter (simulating tape
// head frequency loss) and wobbles in pitch (wow from motor
// irregularities). The "age" control darkens and degrades the
// repeats like worn tape.

use conjuredsp::*;
setup!();

params! {
    TIME = time_ms().min(50.0).max(800.0).default(300.0),
    FEEDBACK = param(0.0, 0.95).default(0.5),
    WOW = param(0.0, 1.0).default(0.3),
    AGE = param(0.0, 1.0).default(0.5),
    MIX = mix().default(0.5),
}

const MAX_DELAY: usize = 96000;

static mut DELAYS: [DelayLine<MAX_DELAY>; MAX_CH] = [DelayLine::new(); MAX_CH];
static mut LP: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut HP: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut WOW_PHASE: f64 = 0.0;
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
        let wow = ctx.param(WOW) as f64;
        let age = ctx.param(AGE) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        // Age controls the filter: new tape = 10kHz, old tape = 2kHz
        let lp_freq = 10000.0 - age * 8000.0;
        let hp_freq = 40.0 + age * 160.0;

        let two_pi = 2.0 * core::f64::consts::PI;
        let wow_depth = wow * 8.0; // samples of wow

        for ch in 0..ctx.channels() {
            LP[ch].set_coeffs(BiquadCoeffs::lowpass(lp_freq, 0.7, sr));
            HP[ch].set_coeffs(BiquadCoeffs::highpass(hp_freq, 0.7, sr));
        }

        for i in 0..ctx.frames() {
            // Wow modulation
            let mut wow_mod = (two_pi * WOW_PHASE).sin() * wow_depth;
            wow_mod += (rng() - 0.5) * wow * 1.0; // noise

            let mut delay_samples = delay_ms * 0.001 * sr + wow_mod;
            if delay_samples < 1.0 {
                delay_samples = 1.0;
            }
            if delay_samples > (MAX_DELAY - 1) as f64 {
                delay_samples = (MAX_DELAY - 1) as f64;
            }

            for ch in 0..ctx.channels() {
                let mut delayed = DELAYS[ch].read_cubic(delay_samples) as f64;

                // Tape coloring on feedback path
                delayed = LP[ch].process_sample(delayed);
                delayed = HP[ch].process_sample(delayed);

                // Soft saturation in feedback (tape compression)
                delayed = (delayed * 1.2).tanh() * 0.85;

                DELAYS[ch].write((ctx.input(ch, i) as f64 + delayed * feedback) as f32);

                ctx.set_output(
                    ch,
                    i,
                    (ctx.input(ch, i) as f64 * (1.0 - wet_mix) + delayed * wet_mix) as f32,
                );
            }

            WOW_PHASE = (WOW_PHASE + 0.5 / sr) % 1.0;
        }
    }
}
