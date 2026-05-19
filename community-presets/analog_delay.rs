// Analog Delay — bucket brigade device (BBD) emulation.
//
// Models the warm, dark character of analog delay chips like the
// MN3005 and MN3207. Each repeat passes through bandpass filtering
// and subtle soft clipping.

use conjuredsp::*;
setup!();

params! {
    TIME = time_ms().min(20.0).max(600.0).default(300.0),
    FEEDBACK = param(0.0, 0.95).default(0.5),
    COLOR = param(0.0, 1.0).default(0.6),
    MIX = mix().default(0.5),
}

const MAX_DELAY: usize = 64000;

static mut DELAYS: [DelayLine<MAX_DELAY>; MAX_CH] = [DelayLine::new(); MAX_CH];
static mut LP: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut HP: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];

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
        let color = ctx.param(COLOR) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        // BBD bandwidth: limited on both ends
        let lp_freq = 6000.0 - color * 4500.0;
        let hp_freq = 100.0 + color * 200.0;

        let mut delay_samples = delay_ms * 0.001 * sr;
        if delay_samples < 1.0 {
            delay_samples = 1.0;
        }

        for ch in 0..ctx.channels() {
            LP[ch].set_coeffs(BiquadCoeffs::lowpass(lp_freq, 0.7, sr));
            HP[ch].set_coeffs(BiquadCoeffs::highpass(hp_freq, 0.7, sr));

            for i in 0..ctx.frames() {
                let mut delayed = DELAYS[ch].read(delay_samples) as f64;

                // BBD coloring: bandpass + soft saturation
                delayed = LP[ch].process_sample(delayed);
                delayed = HP[ch].process_sample(delayed);
                delayed = (delayed * 1.1).tanh(); // subtle compression

                DELAYS[ch].write((ctx.input(ch, i) as f64 + delayed * feedback) as f32);

                ctx.set_output(
                    ch,
                    i,
                    (ctx.input(ch, i) as f64 * (1.0 - wet_mix) + delayed * wet_mix) as f32,
                );
            }
        }
    }
}
