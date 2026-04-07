// Shimmer Delay — delay with octave-shifted feedback.
//
// Each delay repeat is pitch-shifted up by an octave via ring
// modulation approximation, creating ethereal, crystalline trails
// that rise endlessly.

use conjuredsp::*;
setup!();

params! {
    TIME = time_ms().min(100.0).max(800.0).default(400.0),
    FEEDBACK = param(0.0, 0.95).default(0.6),
    SHIMMER = param(0.0, 1.0).default(0.5),
    DAMPING = param(0.0, 1.0).default(0.3),
    MIX = mix().default(0.5),
}

const MAX_DELAY: usize = 96000;

static mut DELAYS: [DelayLine<MAX_DELAY>; MAX_CH] = [DelayLine::new(); MAX_CH];
static mut LP: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut OCTAVE_PHASE: [f64; MAX_CH] = [0.0; MAX_CH];

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
        let shimmer = ctx.param(SHIMMER) as f64;
        let damping = ctx.param(DAMPING) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        let mut delay_samples = delay_ms * 0.001 * sr;
        if delay_samples < 1.0 {
            delay_samples = 1.0;
        }

        let lp_freq = 16000.0 - damping * 12000.0;
        let two_pi = 2.0 * core::f64::consts::PI;

        for ch in 0..ctx.channels() {
            LP[ch].set_coeffs(BiquadCoeffs::lowpass(lp_freq, 0.7, sr));
        }

        for i in 0..ctx.frames() {
            for ch in 0..ctx.channels() {
                let delayed_raw = DELAYS[ch].read(delay_samples) as f64;

                // Damping filter
                let delayed = LP[ch].process_sample(delayed_raw);

                // Octave-up shimmer via ring modulation approximation
                let oct_signal = delayed * (two_pi * OCTAVE_PHASE[ch]).cos();
                OCTAVE_PHASE[ch] = (OCTAVE_PHASE[ch] + 2.0 * 440.0 / sr) % 1.0;

                // Blend normal and shimmer feedback
                let fb_signal = delayed * (1.0 - shimmer) + oct_signal * shimmer;

                DELAYS[ch].write((ctx.input(ch, i) as f64 + fb_signal * feedback) as f32);

                ctx.set_output(
                    ch,
                    i,
                    (ctx.input(ch, i) as f64 * (1.0 - wet_mix) + delayed * wet_mix) as f32,
                );
            }
        }
    }
}
