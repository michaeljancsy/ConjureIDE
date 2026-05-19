// Dub Delay — classic Jamaican dub/reggae delay.
//
// The sound of King Tubby and Lee "Scratch" Perry: warm, heavily
// filtered delay with high feedback creating cascading, darkening
// echoes. Wobble adds tape-like pitch instability.

use conjuredsp::*;
setup!();

params! {
    TIME = time_ms().min(100.0).max(800.0).default(375.0),
    FEEDBACK = param(0.0, 0.95).default(0.7),
    FILTER = param(0.0, 1.0).default(0.6),
    WOBBLE = param(0.0, 1.0).default(0.4),
    MIX = mix().default(0.5),
}

const MAX_DELAY: usize = 96000;

static mut DELAYS: [DelayLine<MAX_DELAY>; MAX_CH] = [DelayLine::new(); MAX_CH];
static mut LP: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut HP: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
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

    unsafe {
        let delay_ms = ctx.param(TIME) as f64;
        let feedback = ctx.param(FEEDBACK) as f64;
        let darkness = ctx.param(FILTER) as f64;
        let wobble = ctx.param(WOBBLE) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        let two_pi = 2.0 * core::f64::consts::PI;

        let lp_freq = 3000.0 - darkness * 2500.0;
        let hp_freq = 100.0 + darkness * 200.0;

        for ch in 0..ctx.channels() {
            LP[ch].set_coeffs(BiquadCoeffs::lowpass(lp_freq, 0.8, sr));
            HP[ch].set_coeffs(BiquadCoeffs::highpass(hp_freq, 0.7, sr));
        }

        for i in 0..ctx.frames() {
            // Tape wobble
            let modulation = (two_pi * PHASE).sin() * wobble * 5.0;
            let mut delay_samples = delay_ms * 0.001 * sr + modulation;
            if delay_samples < 1.0 {
                delay_samples = 1.0;
            }
            if delay_samples > (MAX_DELAY - 1) as f64 {
                delay_samples = (MAX_DELAY - 1) as f64;
            }

            for ch in 0..ctx.channels() {
                let mut delayed = DELAYS[ch].read_cubic(delay_samples) as f64;

                // Heavy filtering in feedback — the dub sound
                delayed = LP[ch].process_sample(delayed);
                delayed = HP[ch].process_sample(delayed);

                // Dub-style saturation (mixing desk driven hot)
                delayed = (delayed * 1.3).tanh() * 0.8;

                DELAYS[ch].write((ctx.input(ch, i) as f64 + delayed * feedback) as f32);

                ctx.set_output(
                    ch,
                    i,
                    (ctx.input(ch, i) as f64 * (1.0 - wet_mix) + delayed * wet_mix) as f32,
                );
            }

            PHASE = (PHASE + 0.4 / sr) % 1.0;
        }
    }
}
