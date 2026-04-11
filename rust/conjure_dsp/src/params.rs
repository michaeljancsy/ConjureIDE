// Parameter addresses — must match the Swift AUParameterTree in ConjureDSPExtensionAudioUnit.swift.
// Addresses are 0-based (0–15) matching AUParameterAddress.

/// Maximum number of parameters exposed to the DAW.
pub const PARAM_COUNT: usize = 16;

/// Rich metadata for a single parameter, declared by scripts via `PARAMS` dict.
#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
pub struct ParamMetadata {
    /// Display name (title-cased) for the DAW/UI parameter label.
    pub name: String,
    /// Original key from the PARAMS dict (e.g., "threshold", "bit_depth").
    /// Used as the dict key when passing params to Python scripts.
    #[serde(default)]
    pub key: String,
    pub min: f32,
    pub max: f32,
    pub default: f32,
    pub unit: String,
    /// Mapping curve: "linear" (default), "log" (exponential/logarithmic).
    /// Log curve: min * (max/min)^normalized — ideal for frequency and time params.
    #[serde(default = "default_curve")]
    pub curve: String,
    /// Display style: "slider" (default), "toggle", "choice", or "integer".
    #[serde(default = "default_style")]
    pub style: String,
    /// Option labels for "choice" style parameters (e.g., ["Low", "Mid", "High"]).
    #[serde(default)]
    pub options: Option<Vec<String>>,
}

fn default_curve() -> String {
    "linear".to_string()
}

fn default_style() -> String {
    "slider".to_string()
}

impl ParamMetadata {
    /// Whether this parameter snaps to integer values.
    pub fn is_integer(&self) -> bool {
        self.style == "integer"
    }

    /// Map a normalized 0–1 value to the actual parameter range.
    /// For integer-styled params, the result is rounded to the nearest whole
    /// number and clamped to `[min, max]` so scripts always receive an exact
    /// integer-valued float.
    pub fn denormalize(&self, normalized: f32) -> f32 {
        let n = normalized.clamp(0.0, 1.0);
        let raw = if self.curve == "log" && self.min > 0.0 && self.max > 0.0 {
            // Log curve: min * (max/min)^n
            self.min * (self.max / self.min).powf(n)
        } else {
            // Linear
            self.min + n * (self.max - self.min)
        };
        if self.is_integer() {
            let lo = self.min.min(self.max);
            let hi = self.min.max(self.max);
            raw.round().clamp(lo, hi)
        } else {
            raw
        }
    }

    /// Map an actual parameter value to the normalized 0–1 range.
    /// For integer-styled params, the input is rounded to the nearest whole
    /// number first so round-trips through `denormalize`/`normalize` are stable.
    pub fn normalize(&self, actual: f32) -> f32 {
        let actual = if self.is_integer() {
            actual.round()
        } else {
            actual
        };
        if self.curve == "log" && self.min > 0.0 && self.max > 0.0 {
            // Inverse of log curve: log(actual/min) / log(max/min)
            let ratio = (actual / self.min).max(f32::EPSILON);
            let range = (self.max / self.min).ln();
            if range.abs() < f32::EPSILON {
                return 0.0;
            }
            (ratio.ln() / range).clamp(0.0, 1.0)
        } else {
            // Linear
            let range = self.max - self.min;
            if range.abs() < f32::EPSILON {
                return 0.0;
            }
            ((actual - self.min) / range).clamp(0.0, 1.0)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn linear_param(min: f32, max: f32) -> ParamMetadata {
        ParamMetadata {
            name: "Test".into(),
            key: "test".into(),
            min,
            max,
            default: min,
            unit: "".into(),
            curve: "linear".into(),
            style: "slider".into(),
            options: None,
        }
    }

    fn log_param(min: f32, max: f32) -> ParamMetadata {
        ParamMetadata {
            name: "Freq".into(),
            key: "freq".into(),
            min,
            max,
            default: min,
            unit: "Hz".into(),
            curve: "log".into(),
            style: "slider".into(),
            options: None,
        }
    }

    fn integer_param(min: f32, max: f32) -> ParamMetadata {
        ParamMetadata {
            name: "Stages".into(),
            key: "stages".into(),
            min,
            max,
            default: min,
            unit: "".into(),
            curve: "linear".into(),
            style: "integer".into(),
            options: None,
        }
    }

    #[test]
    fn denormalize_linear_endpoints() {
        let p = linear_param(10.0, 100.0);
        assert!((p.denormalize(0.0) - 10.0).abs() < 1e-5);
        assert!((p.denormalize(1.0) - 100.0).abs() < 1e-5);
    }

    #[test]
    fn denormalize_linear_midpoint() {
        let p = linear_param(0.0, 200.0);
        assert!((p.denormalize(0.5) - 100.0).abs() < 1e-5);
    }

    #[test]
    fn denormalize_log_endpoints() {
        let p = log_param(20.0, 20000.0);
        assert!((p.denormalize(0.0) - 20.0).abs() < 1e-3);
        assert!((p.denormalize(1.0) - 20000.0).abs() < 1.0);
    }

    #[test]
    fn denormalize_log_midpoint_is_geometric_mean() {
        let p = log_param(20.0, 20000.0);
        let mid = p.denormalize(0.5);
        let expected = (20.0_f32 * 20000.0).sqrt(); // geometric mean ≈ 632.45
        assert!((mid - expected).abs() < 1.0, "mid={mid}, expected={expected}");
    }

    #[test]
    fn normalize_linear_roundtrip() {
        let p = linear_param(-60.0, 12.0);
        for &n in &[0.0_f32, 0.25, 0.5, 0.75, 1.0] {
            let actual = p.denormalize(n);
            let back = p.normalize(actual);
            assert!((back - n).abs() < 1e-5, "n={n}, actual={actual}, back={back}");
        }
    }

    #[test]
    fn normalize_log_roundtrip() {
        let p = log_param(20.0, 20000.0);
        for &n in &[0.0_f32, 0.25, 0.5, 0.75, 1.0] {
            let actual = p.denormalize(n);
            let back = p.normalize(actual);
            assert!((back - n).abs() < 1e-4, "n={n}, actual={actual}, back={back}");
        }
    }

    #[test]
    fn normalize_linear_zero_range_returns_zero() {
        let p = linear_param(5.0, 5.0);
        assert_eq!(p.normalize(5.0), 0.0);
    }

    #[test]
    fn denormalize_clamps_input() {
        let p = linear_param(0.0, 100.0);
        assert!((p.denormalize(-0.5) - 0.0).abs() < 1e-5);
        assert!((p.denormalize(1.5) - 100.0).abs() < 1e-5);
    }

    #[test]
    fn integer_denormalize_endpoints() {
        let p = integer_param(2.0, 6.0);
        assert_eq!(p.denormalize(0.0), 2.0);
        assert_eq!(p.denormalize(1.0), 6.0);
    }

    #[test]
    fn integer_denormalize_midpoint_snaps() {
        let p = integer_param(2.0, 6.0);
        // Linear midpoint of [2, 6] is 4.0 — already integer
        assert_eq!(p.denormalize(0.5), 4.0);
        // 0.6 → linear 4.4 → rounds to 4
        assert_eq!(p.denormalize(0.6), 4.0);
        // 0.7 → linear 4.8 → rounds to 5
        assert_eq!(p.denormalize(0.7), 5.0);
        // 0.1 → linear 2.4 → rounds to 2
        assert_eq!(p.denormalize(0.1), 2.0);
        // 0.9 → linear 5.6 → rounds to 6
        assert_eq!(p.denormalize(0.9), 6.0);
    }

    #[test]
    fn integer_denormalize_clamps_to_range() {
        let p = integer_param(1.0, 16.0);
        assert_eq!(p.denormalize(-0.5), 1.0);
        assert_eq!(p.denormalize(1.5), 16.0);
    }

    #[test]
    fn integer_normalize_roundtrip_at_each_step() {
        let p = integer_param(2.0, 6.0);
        // Each integer value should normalize → denormalize back to itself
        for v in [2.0_f32, 3.0, 4.0, 5.0, 6.0] {
            let n = p.normalize(v);
            let back = p.denormalize(n);
            assert_eq!(back, v, "v={v}, n={n}, back={back}");
        }
    }

    #[test]
    fn integer_is_integer_helper() {
        let p = integer_param(0.0, 10.0);
        assert!(p.is_integer());
        let s = linear_param(0.0, 10.0);
        assert!(!s.is_integer());
    }

    #[test]
    fn log_with_negative_min_falls_back_to_linear() {
        let mut p = log_param(20.0, 20000.0);
        p.min = -10.0;
        // Should use linear since min <= 0
        let result = p.denormalize(0.5);
        let expected = -10.0 + 0.5 * (20000.0 - (-10.0));
        assert!((result - expected).abs() < 1e-3);
    }
}
