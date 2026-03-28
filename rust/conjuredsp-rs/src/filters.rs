use core::f64::consts::PI;

/// Biquad filter coefficients (normalized, a0 = 1).
///
/// Use the static methods to compute coefficients for standard filter types
/// (Audio EQ Cookbook formulas), then pass to a [`Biquad`] instance.
#[derive(Clone, Copy)]
pub struct BiquadCoeffs {
    pub b0: f64,
    pub b1: f64,
    pub b2: f64,
    pub a1: f64,
    pub a2: f64,
}

impl BiquadCoeffs {
    /// Low-pass filter. Passes frequencies below cutoff.
    pub fn lowpass(freq: f64, q: f64, sample_rate: f64) -> Self {
        let w0 = 2.0 * PI * freq / sample_rate;
        let cos_w0 = w0.cos();
        let alpha = w0.sin() / (2.0 * q);
        let a0 = 1.0 + alpha;
        BiquadCoeffs {
            b0: (1.0 - cos_w0) / 2.0 / a0,
            b1: (1.0 - cos_w0) / a0,
            b2: (1.0 - cos_w0) / 2.0 / a0,
            a1: -2.0 * cos_w0 / a0,
            a2: (1.0 - alpha) / a0,
        }
    }

    /// High-pass filter. Passes frequencies above cutoff.
    pub fn highpass(freq: f64, q: f64, sample_rate: f64) -> Self {
        let w0 = 2.0 * PI * freq / sample_rate;
        let cos_w0 = w0.cos();
        let alpha = w0.sin() / (2.0 * q);
        let a0 = 1.0 + alpha;
        BiquadCoeffs {
            b0: (1.0 + cos_w0) / 2.0 / a0,
            b1: -(1.0 + cos_w0) / a0,
            b2: (1.0 + cos_w0) / 2.0 / a0,
            a1: -2.0 * cos_w0 / a0,
            a2: (1.0 - alpha) / a0,
        }
    }

    /// Band-pass filter (constant skirt gain). Passes a frequency band.
    pub fn bandpass(freq: f64, q: f64, sample_rate: f64) -> Self {
        let w0 = 2.0 * PI * freq / sample_rate;
        let cos_w0 = w0.cos();
        let alpha = w0.sin() / (2.0 * q);
        let a0 = 1.0 + alpha;
        BiquadCoeffs {
            b0: alpha / a0,
            b1: 0.0,
            b2: -alpha / a0,
            a1: -2.0 * cos_w0 / a0,
            a2: (1.0 - alpha) / a0,
        }
    }

    /// Notch (band-reject) filter. Removes a frequency band.
    pub fn notch(freq: f64, q: f64, sample_rate: f64) -> Self {
        let w0 = 2.0 * PI * freq / sample_rate;
        let cos_w0 = w0.cos();
        let alpha = w0.sin() / (2.0 * q);
        let a0 = 1.0 + alpha;
        BiquadCoeffs {
            b0: 1.0 / a0,
            b1: -2.0 * cos_w0 / a0,
            b2: 1.0 / a0,
            a1: -2.0 * cos_w0 / a0,
            a2: (1.0 - alpha) / a0,
        }
    }

    /// Peaking EQ filter. Boosts or cuts at the center frequency.
    pub fn peak(freq: f64, q: f64, gain_db: f64, sample_rate: f64) -> Self {
        let w0 = 2.0 * PI * freq / sample_rate;
        let cos_w0 = w0.cos();
        let a_amp = (10.0_f64).powf(gain_db / 40.0);
        let alpha = w0.sin() / (2.0 * q);
        let a0 = 1.0 + alpha / a_amp;
        BiquadCoeffs {
            b0: (1.0 + alpha * a_amp) / a0,
            b1: -2.0 * cos_w0 / a0,
            b2: (1.0 - alpha * a_amp) / a0,
            a1: -2.0 * cos_w0 / a0,
            a2: (1.0 - alpha / a_amp) / a0,
        }
    }

    /// Low shelf filter. Boosts or cuts frequencies below the cutoff.
    pub fn lowshelf(freq: f64, q: f64, gain_db: f64, sample_rate: f64) -> Self {
        let w0 = 2.0 * PI * freq / sample_rate;
        let cos_w0 = w0.cos();
        let sin_w0 = w0.sin();
        let a_amp = (10.0_f64).powf(gain_db / 40.0);
        let alpha = sin_w0 / (2.0 * q);
        let two_sqrt_a_alpha = 2.0 * a_amp.sqrt() * alpha;
        let a0 = (a_amp + 1.0) + (a_amp - 1.0) * cos_w0 + two_sqrt_a_alpha;
        BiquadCoeffs {
            b0: (a_amp * ((a_amp + 1.0) - (a_amp - 1.0) * cos_w0 + two_sqrt_a_alpha)) / a0,
            b1: (2.0 * a_amp * ((a_amp - 1.0) - (a_amp + 1.0) * cos_w0)) / a0,
            b2: (a_amp * ((a_amp + 1.0) - (a_amp - 1.0) * cos_w0 - two_sqrt_a_alpha)) / a0,
            a1: (-2.0 * ((a_amp - 1.0) + (a_amp + 1.0) * cos_w0)) / a0,
            a2: ((a_amp + 1.0) + (a_amp - 1.0) * cos_w0 - two_sqrt_a_alpha) / a0,
        }
    }

    /// High shelf filter. Boosts or cuts frequencies above the cutoff.
    pub fn highshelf(freq: f64, q: f64, gain_db: f64, sample_rate: f64) -> Self {
        let w0 = 2.0 * PI * freq / sample_rate;
        let cos_w0 = w0.cos();
        let sin_w0 = w0.sin();
        let a_amp = (10.0_f64).powf(gain_db / 40.0);
        let alpha = sin_w0 / (2.0 * q);
        let two_sqrt_a_alpha = 2.0 * a_amp.sqrt() * alpha;
        let a0 = (a_amp + 1.0) - (a_amp - 1.0) * cos_w0 + two_sqrt_a_alpha;
        BiquadCoeffs {
            b0: (a_amp * ((a_amp + 1.0) + (a_amp - 1.0) * cos_w0 + two_sqrt_a_alpha)) / a0,
            b1: (-2.0 * a_amp * ((a_amp - 1.0) + (a_amp + 1.0) * cos_w0)) / a0,
            b2: (a_amp * ((a_amp + 1.0) + (a_amp - 1.0) * cos_w0 - two_sqrt_a_alpha)) / a0,
            a1: (2.0 * ((a_amp - 1.0) - (a_amp + 1.0) * cos_w0)) / a0,
            a2: ((a_amp + 1.0) - (a_amp - 1.0) * cos_w0 - two_sqrt_a_alpha) / a0,
        }
    }

    /// All-pass filter. Passes all frequencies, shifts phase.
    pub fn allpass(freq: f64, q: f64, sample_rate: f64) -> Self {
        let w0 = 2.0 * PI * freq / sample_rate;
        let cos_w0 = w0.cos();
        let alpha = w0.sin() / (2.0 * q);
        let a0 = 1.0 + alpha;
        BiquadCoeffs {
            b0: (1.0 - alpha) / a0,
            b1: -2.0 * cos_w0 / a0,
            b2: (1.0 + alpha) / a0,
            a1: -2.0 * cos_w0 / a0,
            a2: (1.0 - alpha) / a0,
        }
    }
}

/// Stateful biquad filter using Direct Form II Transposed.
///
/// Create one per channel. Store in `static mut` for persistence across callbacks.
///
/// ```ignore
/// static mut FILTERS: [Biquad; 2] = [Biquad::new(); 2];
/// ```
#[derive(Clone, Copy)]
pub struct Biquad {
    b0: f64,
    b1: f64,
    b2: f64,
    a1: f64,
    a2: f64,
    z1: f64,
    z2: f64,
}

impl Biquad {
    /// Create a passthrough filter (no filtering).
    pub const fn new() -> Self {
        Biquad {
            b0: 1.0,
            b1: 0.0,
            b2: 0.0,
            a1: 0.0,
            a2: 0.0,
            z1: 0.0,
            z2: 0.0,
        }
    }

    /// Update filter coefficients without resetting state.
    #[inline]
    pub fn set_coeffs(&mut self, coeffs: BiquadCoeffs) {
        self.b0 = coeffs.b0;
        self.b1 = coeffs.b1;
        self.b2 = coeffs.b2;
        self.a1 = coeffs.a1;
        self.a2 = coeffs.a2;
    }

    /// Process a single sample through the filter.
    #[inline]
    pub fn process_sample(&mut self, x: f64) -> f64 {
        let y = self.b0 * x + self.z1;
        self.z1 = self.b1 * x - self.a1 * y + self.z2;
        self.z2 = self.b2 * x - self.a2 * y;
        y
    }

    /// Reset filter state to zero.
    pub fn reset(&mut self) {
        self.z1 = 0.0;
        self.z2 = 0.0;
    }
}

#[cfg(test)]
mod tests {
    extern crate std;
    use super::*;
    use crate::dsp::db_to_gain;

    const FREQ: f64 = 1000.0;
    const Q: f64 = 0.707;
    const SR: f64 = 44100.0;
    const N: usize = 1000;

    /// Process N samples of constant DC=1.0 through a filter and return the last output.
    fn dc_response(coeffs: BiquadCoeffs) -> f64 {
        let mut f = Biquad::new();
        f.set_coeffs(coeffs);
        let mut out = 0.0;
        for _ in 0..N {
            out = f.process_sample(1.0);
        }
        out
    }

    #[test]
    fn test_lowpass_passes_dc() {
        let out = dc_response(BiquadCoeffs::lowpass(FREQ, Q, SR));
        assert!((out - 1.0).abs() < 1e-4, "lowpass DC response: {}", out);
    }

    #[test]
    fn test_highpass_rejects_dc() {
        let out = dc_response(BiquadCoeffs::highpass(FREQ, Q, SR));
        assert!(out.abs() < 1e-4, "highpass DC response: {}", out);
    }

    #[test]
    fn test_bandpass_rejects_dc() {
        let out = dc_response(BiquadCoeffs::bandpass(FREQ, Q, SR));
        assert!(out.abs() < 1e-4, "bandpass DC response: {}", out);
    }

    #[test]
    fn test_notch_passes_dc() {
        let out = dc_response(BiquadCoeffs::notch(FREQ, Q, SR));
        assert!((out - 1.0).abs() < 1e-4, "notch DC response: {}", out);
    }

    #[test]
    fn test_allpass_passes_dc() {
        let out = dc_response(BiquadCoeffs::allpass(FREQ, Q, SR));
        assert!((out - 1.0).abs() < 1e-4, "allpass DC response: {}", out);
    }

    #[test]
    fn test_peak_0db_passes_dc() {
        let out = dc_response(BiquadCoeffs::peak(FREQ, Q, 0.0, SR));
        assert!((out - 1.0).abs() < 1e-4, "peak 0dB DC response: {}", out);
    }

    #[test]
    fn test_lowshelf_boost_dc() {
        let gain_db = 6.0;
        let out = dc_response(BiquadCoeffs::lowshelf(FREQ, Q, gain_db, SR));
        let expected = db_to_gain(gain_db);
        assert!(
            (out - expected).abs() < 0.1,
            "lowshelf +6dB DC response: {} (expected ~{})",
            out,
            expected
        );
    }

    #[test]
    fn test_highshelf_no_boost_dc() {
        let out = dc_response(BiquadCoeffs::highshelf(FREQ, Q, 6.0, SR));
        // DC should not be boosted by high shelf — should be near 1.0
        assert!(
            (out - 1.0).abs() < 0.1,
            "highshelf +6dB DC response: {} (expected ~1.0)",
            out
        );
    }

    #[test]
    fn test_biquad_new_is_passthrough() {
        let mut f = Biquad::new();
        for i in 0..10 {
            let input = i as f64 * 0.1;
            let output = f.process_sample(input);
            assert!(
                (output - input).abs() < 1e-10,
                "passthrough failed at sample {}",
                i
            );
        }
    }

    #[test]
    fn test_biquad_reset_zeros_state() {
        let mut f = Biquad::new();
        f.set_coeffs(BiquadCoeffs::lowpass(FREQ, Q, SR));
        // Feed some signal
        for _ in 0..100 {
            f.process_sample(1.0);
        }
        f.reset();
        // After reset, internal state is zero. Feed 0.0 and expect 0.0 output.
        let out = f.process_sample(0.0);
        assert!(out.abs() < 1e-10, "after reset, expected 0.0, got {}", out);
    }

    #[test]
    fn test_impulse_convergence() {
        let mut f = Biquad::new();
        f.set_coeffs(BiquadCoeffs::lowpass(FREQ, Q, SR));
        // Feed impulse: 1 sample of 1.0, then 999 of 0.0
        f.process_sample(1.0);
        let mut last = 0.0;
        for _ in 0..999 {
            last = f.process_sample(0.0);
        }
        assert!(
            last.abs() < 1e-4,
            "impulse response should converge near 0, got {}",
            last
        );
    }
}
