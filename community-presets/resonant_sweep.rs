// Resonant Sweep — slow automated filter sweep.

use conjuredsp::*;
setup!();

params! {
    RATE = param(0.01, 2.0).unit("Hz").default(0.1),
    MIN_FREQ = freq().min(50.0).max(500.0).default(100.0),
    MAX_FREQ = freq().min(2000.0).max(16000.0).default(8000.0),
    RESONANCE = param(0.5, 20.0).unit("Q").default(5.0),
    TYPE = choice(&["Low", "Band", "High"]),
}

static mut FILTERS: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
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
        let rate = ctx.param(RATE) as f64;
        let min_f = ctx.param(MIN_FREQ) as f64;
        let max_f = ctx.param(MAX_FREQ) as f64;
        let q = ctx.param(RESONANCE) as f64;
        let ftype = ctx.param(TYPE) as i32;

        let log_min = min_f.ln();
        let log_max = max_f.ln();

        for i in 0..ctx.frames() {
            let t = PHASE;
            let lfo = 4.0 * (t - 0.5).abs() - 1.0;
            let sweep = 0.5 + 0.5 * lfo;

            let sweep_freq = (log_min + (log_max - log_min) * sweep).exp().min(sr * 0.45);

            let coeffs = match ftype {
                0 => BiquadCoeffs::lowpass(sweep_freq, q, sr),
                1 => BiquadCoeffs::bandpass(sweep_freq, q, sr),
                _ => BiquadCoeffs::highpass(sweep_freq, q, sr),
            };

            for c in 0..ctx.channels() {
                FILTERS[c].set_coeffs(coeffs);
                ctx.set_output(c, i, FILTERS[c].process_sample(ctx.input(c, i) as f64) as f32);
            }

            PHASE = (PHASE + rate / sr) % 1.0;
        }
    }
}
