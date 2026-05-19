// Multi-Band Distortion — independent distortion per frequency band.

use conjuredsp::*;
setup!();

params! {
    LOW_XOVER = freq().min(100.0).max(500.0).default(250.0),
    HIGH_XOVER = freq().min(2000.0).max(8000.0).default(4000.0),
    LOW_DRIVE = param(1.0, 20.0).unit("x").default(2.0),
    MID_DRIVE = param(1.0, 20.0).unit("x").default(5.0),
    HIGH_DRIVE = param(1.0, 20.0).unit("x").default(3.0),
}

static mut LP1: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut HP1: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut LP2: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut HP2: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];

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
        let low_freq = ctx.param(LOW_XOVER) as f64;
        let high_freq = ctx.param(HIGH_XOVER) as f64;
        let low_drv = ctx.param(LOW_DRIVE) as f64;
        let mid_drv = ctx.param(MID_DRIVE) as f64;
        let high_drv = ctx.param(HIGH_DRIVE) as f64;

        for c in 0..ctx.channels() {
            LP1[c].set_coeffs(BiquadCoeffs::lowpass(low_freq, 0.7, sr));
            HP1[c].set_coeffs(BiquadCoeffs::highpass(low_freq, 0.7, sr));
            LP2[c].set_coeffs(BiquadCoeffs::lowpass(high_freq, 0.7, sr));
            HP2[c].set_coeffs(BiquadCoeffs::highpass(high_freq, 0.7, sr));

            for i in 0..ctx.frames() {
                let x = ctx.input(c, i) as f64;

                let low = LP1[c].process_sample(x);
                let rest = HP1[c].process_sample(x);
                let mid = LP2[c].process_sample(rest);
                let high = HP2[c].process_sample(rest);

                let low = (low * low_drv).tanh();
                let mid = (mid * mid_drv).tanh();
                let high = (high * high_drv).tanh();

                ctx.set_output(c, i, (low + mid + high) as f32);
            }
        }
    }
}
