// Spectral Gate — frequency-dependent noise gate.
//
// Gates the low and high frequency bands independently based on
// their individual levels.

use conjuredsp::*;
setup!();

params! {
    THRESHOLD = db(-60.0, -10.0).default(-35.0),
    CROSSOVER = freq().min(200.0).max(5000.0).default(1000.0),
    MODE = param(0.0, 1.0).default(0.5),
    RELEASE = param(10.0, 500.0).unit("ms").default(50.0),
}

// Two sets of filters: one for the summing pass, one for the output pass
// (Python calls process_sample twice per sample per filter, but biquads are stateful,
// so we need separate filter instances for each pass)
static mut LP_ENV: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut HP_ENV: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut LP_OUT: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut HP_OUT: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut ENV_LO: f64 = 0.0;
static mut ENV_HI: f64 = 0.0;

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
        let thresh = db_to_gain(ctx.param(THRESHOLD) as f64);
        let xover = ctx.param(CROSSOVER) as f64;
        let rel = smooth_coeff(ctx.param(RELEASE) as f64, sr);

        let n_ch = ctx.channels();

        for ch in 0..n_ch {
            LP_ENV[ch].set_coeffs(BiquadCoeffs::lowpass(xover, 0.7, sr));
            HP_ENV[ch].set_coeffs(BiquadCoeffs::highpass(xover, 0.7, sr));
            LP_OUT[ch].set_coeffs(BiquadCoeffs::lowpass(xover, 0.7, sr));
            HP_OUT[ch].set_coeffs(BiquadCoeffs::highpass(xover, 0.7, sr));
        }

        for i in 0..ctx.frames() {
            let mut lo_sum = 0.0;
            let mut hi_sum = 0.0;

            for ch in 0..n_ch {
                let x = ctx.input(ch, i) as f64;
                let lo = LP_ENV[ch].process_sample(x);
                let hi = HP_ENV[ch].process_sample(x);
                lo_sum += lo.abs();
                hi_sum += hi.abs();
            }

            lo_sum /= n_ch as f64;
            hi_sum /= n_ch as f64;

            // Independent envelope followers
            let lo_target = rel * ENV_LO + (1.0 - rel) * lo_sum;
            ENV_LO = if lo_sum > lo_target { lo_sum } else { lo_target };
            let hi_target = rel * ENV_HI + (1.0 - rel) * hi_sum;
            ENV_HI = if hi_sum > hi_target { hi_sum } else { hi_target };

            // Gate gains
            let lo_gate = if ENV_LO > thresh { 1.0 } else { ENV_LO / (thresh + 1e-10) };
            let hi_gate = if ENV_HI > thresh { 1.0 } else { ENV_HI / (thresh + 1e-10) };

            for ch in 0..n_ch {
                let x = ctx.input(ch, i) as f64;
                let lo = LP_OUT[ch].process_sample(x);
                let hi = HP_OUT[ch].process_sample(x);

                ctx.set_output(ch, i, (lo * lo_gate + hi * hi_gate) as f32);
            }
        }
    }
}
