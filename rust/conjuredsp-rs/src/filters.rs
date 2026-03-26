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
