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

#[cfg(test)]
mod tests {
    extern crate std;
    use super::*;

    fn approx_eq(a: f64, b: f64, tol: f64) -> bool {
        (a - b).abs() < tol
    }

    fn approx_eq_f32(a: f32, b: f32, tol: f32) -> bool {
        (a - b).abs() < tol
    }

    // db_to_gain tests
    #[test]
    fn test_db_to_gain_0db() {
        assert!(approx_eq(db_to_gain(0.0), 1.0, 1e-10));
    }

    #[test]
    fn test_db_to_gain_minus_6db() {
        // -6 dB ≈ 0.5012
        assert!(approx_eq(db_to_gain(-6.0), 0.5011872, 1e-4));
    }

    #[test]
    fn test_db_to_gain_minus_20db() {
        assert!(approx_eq(db_to_gain(-20.0), 0.1, 1e-10));
    }

    #[test]
    fn test_db_to_gain_plus_20db() {
        assert!(approx_eq(db_to_gain(20.0), 10.0, 1e-10));
    }

    // gain_to_db tests
    #[test]
    fn test_gain_to_db_unity() {
        assert!(approx_eq(gain_to_db(1.0), 0.0, 1e-10));
    }

    #[test]
    fn test_gain_to_db_half() {
        assert!(approx_eq(gain_to_db(0.5), -6.0206, 1e-3));
    }

    #[test]
    fn test_gain_to_db_zero_clamps() {
        let result = gain_to_db(0.0);
        assert!(result < -500.0, "gain_to_db(0.0) should be very negative, got {}", result);
    }

    // ms_to_samples tests
    #[test]
    fn test_ms_to_samples_1000ms_44100() {
        assert_eq!(ms_to_samples(1000.0, 44100.0), 44100);
    }

    #[test]
    fn test_ms_to_samples_10ms_48000() {
        assert_eq!(ms_to_samples(10.0, 48000.0), 480);
    }

    // samples_to_ms tests
    #[test]
    fn test_samples_to_ms_44100_at_44100() {
        assert!(approx_eq(samples_to_ms(44100, 44100.0), 1000.0, 1e-10));
    }

    #[test]
    fn test_samples_to_ms_480_at_48000() {
        assert!(approx_eq(samples_to_ms(480, 48000.0), 10.0, 1e-10));
    }

    // freq_to_period tests
    #[test]
    fn test_freq_to_period_440hz() {
        let period = freq_to_period(440.0, 44100.0);
        assert!(approx_eq(period, 100.2272727, 1e-4));
    }

    // smooth_coeff tests
    #[test]
    fn test_smooth_coeff_zero_ms() {
        assert_eq!(smooth_coeff(0.0, 44100.0), 0.0);
    }

    #[test]
    fn test_smooth_coeff_negative_ms() {
        assert_eq!(smooth_coeff(-1.0, 44100.0), 0.0);
    }

    #[test]
    fn test_smooth_coeff_large_ms() {
        let alpha = smooth_coeff(1000.0, 44100.0);
        assert!(alpha > 0.99 && alpha < 1.0, "large time_ms should give alpha close to 1.0, got {}", alpha);
    }

    // soft_clip tests
    #[test]
    fn test_soft_clip_zero() {
        assert!(approx_eq(soft_clip(0.0, 5.0), 0.0, 1e-10));
    }

    #[test]
    fn test_soft_clip_small_input() {
        // For small inputs, tanh(x) ≈ x
        let result = soft_clip(0.01, 1.0);
        assert!(approx_eq(result, 0.01, 1e-4));
    }

    // lerp tests
    #[test]
    fn test_lerp_t0() {
        assert!(approx_eq(lerp(3.0, 7.0, 0.0), 3.0, 1e-10));
    }

    #[test]
    fn test_lerp_t1() {
        assert!(approx_eq(lerp(3.0, 7.0, 1.0), 7.0, 1e-10));
    }

    #[test]
    fn test_lerp_t_half() {
        assert!(approx_eq(lerp(3.0, 7.0, 0.5), 5.0, 1e-10));
    }

    // crossfade tests
    #[test]
    fn test_crossfade_mix0() {
        assert!(approx_eq_f32(crossfade(1.0, 0.5, 0.0), 1.0, 1e-6));
    }

    #[test]
    fn test_crossfade_mix1() {
        assert!(approx_eq_f32(crossfade(1.0, 0.5, 1.0), 0.5, 1e-6));
    }

    #[test]
    fn test_crossfade_mix_half() {
        assert!(approx_eq_f32(crossfade(1.0, 0.5, 0.5), 0.75, 1e-6));
    }
}
