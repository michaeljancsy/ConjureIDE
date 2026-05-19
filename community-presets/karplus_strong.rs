// Karplus-Strong — plucked string synthesis from input.
//
// Uses the Karplus-Strong algorithm: a short delay line with
// lowpass-filtered feedback creates a string-like resonance.

use conjuredsp::*;
setup!();

params! {
    PITCH = freq().min(50.0).max(1000.0).default(220.0),
    BRIGHTNESS = param(0.0, 1.0).default(0.6),
    DECAY_TIME = param(0.5, 10.0).unit("s").default(2.0),
    MIX = mix().default(0.6),
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
        let brightness = ctx.param(BRIGHTNESS) as f64;
        let decay_s = ctx.param(DECAY_TIME) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        let mut delay_samples = sr / pitch_hz;
        if delay_samples < 2.0 { delay_samples = 2.0; }
        if delay_samples > (MAX_DELAY - 1) as f64 { delay_samples = (MAX_DELAY - 1) as f64; }

        // Feedback gain for desired decay
        let feedback = if decay_s > 0.0 {
            (10.0f64).powf(-3.0 * delay_samples / (decay_s * sr))
        } else {
            0.0
        };

        // Brightness controls the lowpass in the loop
        let lp_freq = 500.0 + brightness * 8000.0;

        for ch in 0..ctx.channels() {
            LP[ch].set_coeffs(BiquadCoeffs::lowpass(lp_freq, 0.7, sr));

            for i in 0..ctx.frames() {
                let mut delayed = DELAYS[ch].read(delay_samples) as f64;

                // Karplus-Strong: lowpass filter in feedback loop
                delayed = LP[ch].process_sample(delayed);

                // Input excites the string
                let x = ctx.input(ch, i) as f64;
                DELAYS[ch].write((x * 0.5 + delayed * feedback) as f32);

                ctx.set_output(ch, i, (x * (1.0 - wet_mix) + delayed * wet_mix) as f32);
            }
        }
    }
}
