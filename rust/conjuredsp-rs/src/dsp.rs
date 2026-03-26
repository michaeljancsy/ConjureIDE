/// Convert decibels to linear gain. 0 dB = 1.0.
#[inline]
pub fn db_to_gain(db: f64) -> f64 {
    (10.0_f64).powf(db / 20.0)
}

/// Convert linear gain to decibels. Clamps to avoid log(0).
#[inline]
pub fn gain_to_db(gain: f64) -> f64 {
    20.0 * (gain.max(1e-30)).log10()
}

/// Convert milliseconds to sample count (rounded to nearest int).
#[inline]
pub fn ms_to_samples(ms: f64, sample_rate: f64) -> usize {
    (ms * 0.001 * sample_rate + 0.5) as usize
}

/// Convert sample count to milliseconds.
#[inline]
pub fn samples_to_ms(samples: usize, sample_rate: f64) -> f64 {
    samples as f64 * 1000.0 / sample_rate
}

/// Convert frequency in Hz to period in samples.
#[inline]
pub fn freq_to_period(freq: f64, sample_rate: f64) -> f64 {
    sample_rate / freq
}

/// One-pole smoothing coefficient from time constant in ms.
///
/// Returns alpha for: `state = alpha * state + (1 - alpha) * target`
///
/// Larger time_ms = slower smoothing (alpha closer to 1).
#[inline]
pub fn smooth_coeff(time_ms: f64, sample_rate: f64) -> f64 {
    if time_ms <= 0.0 {
        return 0.0;
    }
    (-1.0 / (time_ms * 0.001 * sample_rate)).exp()
}

/// Soft clipper using tanh saturation.
#[inline]
pub fn soft_clip(x: f64, drive: f64) -> f64 {
    (x * drive).tanh()
}

/// Linear interpolation between a and b. t=0 returns a, t=1 returns b.
#[inline]
pub fn lerp(a: f64, b: f64, t: f64) -> f64 {
    a + (b - a) * t
}

/// Linear crossfade between dry and wet signals.
/// mix=0.0 returns dry, mix=1.0 returns wet.
#[inline]
pub fn crossfade(dry: f32, wet: f32, mix: f32) -> f32 {
    dry * (1.0 - mix) + wet * mix
}
