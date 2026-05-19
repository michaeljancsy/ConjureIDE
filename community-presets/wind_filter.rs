// Wind Filter -- wind-like random filtering.
//
// Applies a bandpass filter that wanders randomly like wind --
// slow, unpredictable sweeps with occasional gusts.

use conjuredsp::*;
setup!();

params! {
    SPEED = param(0.0, 1.0).default(0.5),
    INTENSITY = param(0.0, 1.0).default(0.6),
    RESONANCE = param(0.5, 8.0).unit("Q").default(2.0),
}

static mut RNG_STATE: u32 = 12345;

fn rng() -> f64 {
    unsafe {
        RNG_STATE = RNG_STATE.wrapping_mul(1664525).wrapping_add(1013904223);
        RNG_STATE as f64 / 4294967296.0
    }
}

static mut FILTERS: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut NOISE_STATE: f64 = 0.0;

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
        let speed = ctx.param(SPEED) as f64;
        let intensity = ctx.param(INTENSITY) as f64;
        let q = ctx.param(RESONANCE) as f64;

        let change_rate = 0.1 + speed * 5.0;
        let smooth = (-change_rate / sr).exp();

        let min_freq = 200.0_f64;
        let max_freq = 200.0 + intensity * 8000.0;
        let log_min = min_freq.ln();
        let log_max = max_freq.ln();

        for i in 0..ctx.frames() {
            // Random walk with smoothing
            NOISE_STATE = NOISE_STATE * smooth
                + (rng() - 0.5) * (1.0 - smooth) * 2.0;
            NOISE_STATE = NOISE_STATE.max(-1.0).min(1.0);

            // Map noise to frequency
            let t = (NOISE_STATE + 1.0) * 0.5;
            let sweep_freq =
                (log_min + (log_max - log_min) * t).exp().min(sr * 0.45);

            let coeffs = BiquadCoeffs::bandpass(sweep_freq, q, sr);
            for ch in 0..ctx.channels() {
                FILTERS[ch].set_coeffs(coeffs);
                let out =
                    FILTERS[ch].process_sample(ctx.input(ch, i)) as f64
                        * q
                        * 0.3;
                ctx.set_output(ch, i, out as f32);
            }
        }
    }
}
