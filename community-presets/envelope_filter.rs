// Envelope Filter — auto-wah / Mu-Tron III inspired.

use conjuredsp::*;
setup!();

params! {
    SENSITIVITY = param(1.0, 20.0).unit("x").default(8.0),
    MIN_FREQ = freq().min(100.0).max(1000.0).default(200.0),
    MAX_FREQ = freq().min(2000.0).max(10000.0).default(5000.0),
    RESONANCE = param(1.0, 15.0).unit("Q").default(5.0),
    ATTACK = param(1.0, 50.0).unit("ms").default(5.0),
    RELEASE = param(10.0, 500.0).unit("ms").default(80.0),
}

static mut FILTERS: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut ENVELOPE: f64 = 0.0;

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
        let sensitivity = ctx.param(SENSITIVITY) as f64;
        let min_f = ctx.param(MIN_FREQ) as f64;
        let max_f = ctx.param(MAX_FREQ) as f64;
        let q = ctx.param(RESONANCE) as f64;
        let attack_ms = ctx.param(ATTACK) as f64;
        let release_ms = ctx.param(RELEASE) as f64;

        let att_coeff = smooth_coeff(attack_ms, sr);
        let rel_coeff = smooth_coeff(release_ms, sr);

        let log_min = min_f.ln();
        let log_max = max_f.ln();

        for i in 0..ctx.frames() {
            let mut peak: f64 = 0.0;
            for c in 0..ctx.channels() {
                let v = (ctx.input(c, i) as f64).abs();
                if v > peak { peak = v; }
            }

            peak *= sensitivity;

            if peak > ENVELOPE {
                ENVELOPE = att_coeff * ENVELOPE + (1.0 - att_coeff) * peak;
            } else {
                ENVELOPE = rel_coeff * ENVELOPE + (1.0 - rel_coeff) * peak;
            }

            let env_clamped = ENVELOPE.min(1.0);
            let mut sweep_freq = (log_min + (log_max - log_min) * env_clamped).exp();
            sweep_freq = sweep_freq.min(sr * 0.45);

            let coeffs = BiquadCoeffs::bandpass(sweep_freq, q, sr);
            for c in 0..ctx.channels() {
                FILTERS[c].set_coeffs(coeffs);
                ctx.set_output(c, i, (FILTERS[c].process_sample(ctx.input(c, i) as f64) * q * 0.5) as f32);
            }
        }
    }
}
