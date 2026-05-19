// Stereo Widener -- frequency-dependent stereo width control.
//
// Controls stereo width with a single knob: below 1.0 narrows
// toward mono, above 1.0 widens beyond natural stereo. The
// bass_mono control forces low frequencies to mono.

use conjuredsp::*;
setup!();

params! {
    WIDTH = param(0.0, 2.0).default(1.5),
    BASS_MONO = freq().min(50.0).max(500.0).default(200.0),
    BASS_WIDTH = param(0.0, 1.0).default(0.0),
}

static mut LP_L: Biquad = Biquad::new();
static mut LP_R: Biquad = Biquad::new();
static mut HP_L: Biquad = Biquad::new();
static mut HP_R: Biquad = Biquad::new();

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
        let width = ctx.param(WIDTH) as f64;
        let mono_freq = ctx.param(BASS_MONO) as f64;
        let bass_w = ctx.param(BASS_WIDTH) as f64;

        if ctx.channels() < 2 {
            for i in 0..ctx.frames() {
                ctx.set_output(0, i, ctx.input(0, i));
            }
            return;
        }

        LP_L.set_coeffs(BiquadCoeffs::lowpass(mono_freq, 0.7, sr));
        LP_R.set_coeffs(BiquadCoeffs::lowpass(mono_freq, 0.7, sr));
        HP_L.set_coeffs(BiquadCoeffs::highpass(mono_freq, 0.7, sr));
        HP_R.set_coeffs(BiquadCoeffs::highpass(mono_freq, 0.7, sr));

        for i in 0..ctx.frames() {
            let left = ctx.input(0, i) as f64;
            let right = ctx.input(1, i) as f64;

            // Split into low and high
            let lo_l = LP_L.process_sample(left as f32) as f64;
            let lo_r = LP_R.process_sample(right as f32) as f64;
            let hi_l = HP_L.process_sample(left as f32) as f64;
            let hi_r = HP_R.process_sample(right as f32) as f64;

            // Bass mono/width control
            let lo_mid = (lo_l + lo_r) * 0.5;
            let lo_side = (lo_l - lo_r) * 0.5;
            let lo_l_out = lo_mid + lo_side * bass_w;
            let lo_r_out = lo_mid - lo_side * bass_w;

            // High frequency width control
            let hi_mid = (hi_l + hi_r) * 0.5;
            let hi_side = (hi_l - hi_r) * 0.5;
            let hi_l_out = hi_mid + hi_side * width;
            let hi_r_out = hi_mid - hi_side * width;

            ctx.set_output(0, i, (lo_l_out + hi_l_out) as f32);
            ctx.set_output(1, i, (lo_r_out + hi_r_out) as f32);
        }
    }
}
