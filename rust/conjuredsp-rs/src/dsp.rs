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

/// Equal-power (constant-power) crossfade between dry and wet signals.
///
/// `angle = mix * π/2`, gains are `cos(angle)` for dry and `sin(angle)`
/// for wet, so `dry_gain² + wet_gain² = 1` for every `mix` in `[0, 1]`.
/// The perceived loudness of summed uncorrelated signals tracks the
/// sum of squares, so this curve keeps the apparent level constant
/// across the sweep — at `mix=0.5` each gain is `√2/2 ≈ 0.707`, ~3 dB
/// hotter than the linear midpoint of 0.5.
///
/// Reach for this when the dry and wet paths are roughly uncorrelated
/// (reverb / chorus / convolution wet/dry mix, A/B blend of two
/// distinct sources). Prefer [`crossfade`] when the two signals are
/// correlated or near-identical (parameter morphing, smoothing a
/// single source between two states) — there, linear preserves
/// amplitude and equal-power overshoots.
#[inline]
pub fn equal_power_crossfade(dry: f32, wet: f32, mix: f32) -> f32 {
    let angle = mix * core::f32::consts::FRAC_PI_2;
    dry * angle.cos() + wet * angle.sin()
}

/// ConjureDSP house calibration: 0 VU = -18 dBFS (EBU R68).
///
/// Use this constant when scaling RMS or peak detectors to a VU-style
/// reference level so all presets agree on what "0 VU" means.
pub const VU_REF_DBFS: f64 = -18.0;

/// Convert a dBFS sample/RMS level to VU dB under the ConjureDSP
/// house calibration (0 VU = -18 dBFS, EBU R68).
///
/// `dbfs_to_vu(-18.0) == 0.0`. Above-reference levels map to positive
/// VU dB; below-reference levels map to negative VU dB.
#[inline]
pub fn dbfs_to_vu(dbfs: f64) -> f64 {
    dbfs - VU_REF_DBFS
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

    // equal_power_crossfade tests
    #[test]
    fn test_equal_power_crossfade_mix0_returns_dry() {
        // cos(0) = 1, sin(0) = 0 → returns dry untouched.
        assert!(approx_eq_f32(equal_power_crossfade(0.8, 0.3, 0.0), 0.8, 1e-6));
    }

    #[test]
    fn test_equal_power_crossfade_mix1_returns_wet() {
        // cos(π/2) ≈ 0, sin(π/2) = 1 → returns wet untouched.
        assert!(approx_eq_f32(equal_power_crossfade(0.8, 0.3, 1.0), 0.3, 1e-6));
    }

    #[test]
    fn test_equal_power_crossfade_mix_half_both_gains_above_one_half() {
        // At mix=0.5 each gain is √2/2 ≈ 0.7071 — both >0.5, unlike linear
        // crossfade where each gain is exactly 0.5. This is the whole
        // point of equal-power: midpoint is louder, not quieter.
        let sqrt_half = (0.5_f32).sqrt(); // ≈ 0.70710677
        let dry = 1.0_f32;
        let wet = 1.0_f32;
        let out = equal_power_crossfade(dry, wet, 0.5);
        // dry * 0.7071 + wet * 0.7071 = 2 * 0.7071 ≈ 1.4142
        assert!(approx_eq_f32(out, 2.0 * sqrt_half, 1e-6));
        assert!(out > 0.5 + 0.5, "midpoint sum must exceed linear-crossfade sum, got {}", out);
    }

    #[test]
    fn test_equal_power_crossfade_invariant_unity_sum_of_squares() {
        // The equal-power invariant: dry_gain² + wet_gain² = 1 at every mix.
        // Probe with dry=1, wet=0 to read dry_gain, then dry=0, wet=1 to read wet_gain.
        let dry_gain = equal_power_crossfade(1.0, 0.0, 0.5);
        let wet_gain = equal_power_crossfade(0.0, 1.0, 0.5);
        assert!(approx_eq_f32(dry_gain * dry_gain + wet_gain * wet_gain, 1.0, 1e-6));
    }

    // VU calibration tests (0 VU = -18 dBFS, EBU R68)
    #[test]
    fn test_vu_ref_dbfs_constant() {
        assert!(approx_eq(VU_REF_DBFS, -18.0, 1e-12));
    }

    #[test]
    fn test_dbfs_to_vu_at_reference() {
        assert!(approx_eq(dbfs_to_vu(-18.0), 0.0, 1e-9));
    }

    #[test]
    fn test_dbfs_to_vu_full_scale() {
        // 0 dBFS is +18 VU under the EBU R68 calibration.
        assert!(approx_eq(dbfs_to_vu(0.0), 18.0, 1e-9));
    }

    #[test]
    fn test_dbfs_to_vu_below_reference() {
        // -24 dBFS = -6 VU
        assert!(approx_eq(dbfs_to_vu(-24.0), -6.0, 1e-9));
    }
}
