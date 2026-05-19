// Feedback Drone — self-oscillating resonant feedback.
//
// A tuned delay line with feedback at or above unity creates a
// sustained drone at the specified pitch.

use conjuredsp::*;
setup!();

params! {
    PITCH = freq().min(30.0).max(1000.0).default(110.0),
    FEEDBACK = param(0.9, 1.05).default(0.99),
    BRIGHTNESS = param(0.0, 1.0).default(0.4),
    MIX = mix().default(0.5),
}

const MAX_DELAY: usize = 4096;

static mut DELAYS: [DelayLine<MAX_DELAY>; MAX_CH] = [DelayLine::new(); MAX_CH];
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
        let pitch_hz = ctx.param(PITCH) as f64;
        let feedback = ctx.param(FEEDBACK) as f64;
        let brightness = ctx.param(BRIGHTNESS) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        let mut delay_samples = sr / pitch_hz;
        if delay_samples < 2.0 { delay_samples = 2.0; }
        if delay_samples > (MAX_DELAY - 1) as f64 { delay_samples = (MAX_DELAY - 1) as f64; }

        let lp_freq = 500.0 + brightness * 8000.0;

        for ch in 0..ctx.channels() {
            LP[ch].set_coeffs(BiquadCoeffs::lowpass(lp_freq, 0.7, sr));

            for i in 0..ctx.frames() {
                let mut delayed = DELAYS[ch].read(delay_samples) as f64;

                // Filter in feedback loop
                delayed = LP[ch].process_sample(delayed);

                // Soft limit to prevent blowup at feedback > 1.0
                delayed = delayed.tanh();

                let x = ctx.input(ch, i) as f64;
                DELAYS[ch].write((x * 0.3 + delayed * feedback) as f32);

                ctx.set_output(ch, i, (x * (1.0 - wet_mix) + delayed * wet_mix) as f32);
            }
        }
    }
}
