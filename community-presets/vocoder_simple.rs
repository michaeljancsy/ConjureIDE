// Vocoder — channel vocoder for robotic voice.
//
// Splits the input into frequency bands, extracts the amplitude
// envelope of each band, and applies those envelopes to a
// synthesized carrier.

use conjuredsp::*;
setup!();

params! {
    BANDS = param(4.0, 16.0).default(8.0),
    ATTACK = param(1.0, 50.0).unit("ms").default(5.0),
    RELEASE = param(10.0, 200.0).unit("ms").default(50.0),
    SHIFT = param(-12.0, 12.0).unit("st").default(0.0),
}

const NUM_BANDS: usize = 16;

static mut ANALYSIS: [[Biquad; NUM_BANDS]; MAX_CH] = [[Biquad::new(); NUM_BANDS]; MAX_CH];
static mut SYNTHESIS: [[Biquad; NUM_BANDS]; MAX_CH] = [[Biquad::new(); NUM_BANDS]; MAX_CH];
static mut ENVELOPES: [f64; NUM_BANDS] = [0.0; NUM_BANDS];

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
        let n_bands = ctx.param(BANDS) as usize;
        let att = smooth_coeff(ctx.param(ATTACK) as f64, sr);
        let rel = smooth_coeff(ctx.param(RELEASE) as f64, sr);
        let shift_st = ctx.param(SHIFT) as f64;

        let min_f = 100.0f64;
        let max_f = (12000.0f64).min(sr * 0.45);
        let shift_ratio = (2.0f64).powf(shift_st / 12.0);

        for ch in 0..ctx.channels() {
            for i in 0..ctx.frames() {
                let x = ctx.input(ch, i) as f64;

                // Generate carrier: rectified + noisy version of input
                let carrier = x.abs() + x * x * 0.5;

                let mut out = 0.0f64;
                for b in 0..n_bands {
                    // Log-spaced center frequency
                    let t = b as f64 / (n_bands - 1).max(1) as f64;
                    let center = min_f * (max_f / min_f).powf(t);

                    let q = 3.0 + n_bands as f64 * 0.5;

                    // Analysis: extract band energy
                    ANALYSIS[ch][b].set_coeffs(BiquadCoeffs::bandpass(center, q, sr));
                    let band_signal = ANALYSIS[ch][b].process_sample(x);

                    // Envelope follower (only on first channel)
                    if ch == 0 {
                        let level = band_signal.abs() * q;
                        if level > ENVELOPES[b] {
                            ENVELOPES[b] = att * ENVELOPES[b] + (1.0 - att) * level;
                        } else {
                            ENVELOPES[b] = rel * ENVELOPES[b] + (1.0 - rel) * level;
                        }
                    }

                    // Synthesis: filter carrier at (possibly shifted) frequency
                    let synth_freq = (center * shift_ratio).min(sr * 0.45);
                    SYNTHESIS[ch][b].set_coeffs(BiquadCoeffs::bandpass(synth_freq, q, sr));
                    let synth_band = SYNTHESIS[ch][b].process_sample(carrier);

                    // Apply analysis envelope to synthesis band
                    out += synth_band * ENVELOPES[b];
                }

                ctx.set_output(ch, i, (out * 2.0 / n_bands as f64) as f32);
            }
        }
    }
}
