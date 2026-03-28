/// Specification for a single parameter.
///
/// Use the builder functions ([`freq`], [`db`], [`time_ms`], [`mix`], [`pct`],
/// [`toggle`], [`ratio`], [`param`]) to create specs, then customize with
/// `.min()`, `.max()`, `.default()`, `.unit()`, `.curve()`.
#[derive(Clone, Copy)]
pub struct ParamSpec {
    pub min_val: f64,
    pub max_val: f64,
    pub unit_str: &'static str,
    pub default_val: f64,
    pub curve_str: &'static str,
}

impl ParamSpec {
    /// Set the minimum value.
    pub const fn min(mut self, min: f64) -> Self {
        self.min_val = min;
        self
    }

    /// Set the maximum value.
    pub const fn max(mut self, max: f64) -> Self {
        self.max_val = max;
        self
    }

    /// Set the default value.
    pub const fn default(mut self, default: f64) -> Self {
        self.default_val = default;
        self
    }

    /// Set the display unit (e.g., "Hz", "dB", "ms", ":1").
    pub const fn unit(mut self, unit: &'static str) -> Self {
        self.unit_str = unit;
        self
    }

    /// Set the curve type: "linear" (default) or "log".
    pub const fn curve(mut self, curve: &'static str) -> Self {
        self.curve_str = curve;
        self
    }
}

/// Frequency parameter with Hz unit and log curve.
/// Default range: 20–20000 Hz, default value: 1000.
pub const fn freq() -> ParamSpec {
    ParamSpec {
        min_val: 20.0,
        max_val: 20000.0,
        unit_str: "Hz",
        default_val: 1000.0,
        curve_str: "log",
    }
}

/// Decibel parameter with dB unit and linear curve.
/// Default range: -60 to +12 dB, default value: 0.
pub const fn db() -> ParamSpec {
    ParamSpec {
        min_val: -60.0,
        max_val: 12.0,
        unit_str: "dB",
        default_val: 0.0,
        curve_str: "linear",
    }
}

/// Time parameter in milliseconds with log curve.
/// Default range: 0.1–1000 ms, default value: 100.
pub const fn time_ms() -> ParamSpec {
    ParamSpec {
        min_val: 0.1,
        max_val: 1000.0,
        unit_str: "ms",
        default_val: 100.0,
        curve_str: "log",
    }
}

/// Wet/dry mix parameter, 0.0–1.0.
/// Default value: 0.5.
pub const fn mix() -> ParamSpec {
    ParamSpec {
        min_val: 0.0,
        max_val: 1.0,
        unit_str: "",
        default_val: 0.5,
        curve_str: "linear",
    }
}

/// Percentage parameter, 0–100%.
/// Default value: 50.
pub const fn pct() -> ParamSpec {
    ParamSpec {
        min_val: 0.0,
        max_val: 100.0,
        unit_str: "%",
        default_val: 50.0,
        curve_str: "linear",
    }
}

/// On/off toggle parameter (0 or 1).
/// Default value: 0 (off).
pub const fn toggle() -> ParamSpec {
    ParamSpec {
        min_val: 0.0,
        max_val: 1.0,
        unit_str: "",
        default_val: 0.0,
        curve_str: "linear",
    }
}

/// Compression/expansion ratio parameter.
/// Default range: 1–20, unit ":1", default value: 4.
pub const fn ratio() -> ParamSpec {
    ParamSpec {
        min_val: 1.0,
        max_val: 20.0,
        unit_str: ":1",
        default_val: 4.0,
        curve_str: "linear",
    }
}

/// Generic parameter with explicit min/max.
/// Default value is min. Customize with `.unit()`, `.default()`, `.curve()`.
pub const fn param(min: f64, max: f64) -> ParamSpec {
    ParamSpec {
        min_val: min,
        max_val: max,
        unit_str: "",
        default_val: min,
        curve_str: "linear",
    }
}

#[cfg(test)]
mod tests {
    extern crate std;
    use super::*;

    fn approx_eq(a: f64, b: f64, tol: f64) -> bool {
        (a - b).abs() < tol
    }

    #[test]
    fn test_freq_defaults() {
        let p = freq();
        assert!(approx_eq(p.min_val, 20.0, 1e-10));
        assert!(approx_eq(p.max_val, 20000.0, 1e-10));
        assert_eq!(p.unit_str, "Hz");
        assert!(approx_eq(p.default_val, 1000.0, 1e-10));
        assert_eq!(p.curve_str, "log");
    }

    #[test]
    fn test_db_defaults() {
        let p = db();
        assert!(approx_eq(p.min_val, -60.0, 1e-10));
        assert!(approx_eq(p.max_val, 12.0, 1e-10));
        assert_eq!(p.unit_str, "dB");
        assert!(approx_eq(p.default_val, 0.0, 1e-10));
        assert_eq!(p.curve_str, "linear");
    }

    #[test]
    fn test_time_ms_defaults() {
        let p = time_ms();
        assert!(approx_eq(p.min_val, 0.1, 1e-10));
        assert!(approx_eq(p.max_val, 1000.0, 1e-10));
        assert_eq!(p.unit_str, "ms");
        assert!(approx_eq(p.default_val, 100.0, 1e-10));
        assert_eq!(p.curve_str, "log");
    }

    #[test]
    fn test_mix_defaults() {
        let p = mix();
        assert!(approx_eq(p.min_val, 0.0, 1e-10));
        assert!(approx_eq(p.max_val, 1.0, 1e-10));
        assert_eq!(p.unit_str, "");
        assert!(approx_eq(p.default_val, 0.5, 1e-10));
    }

    #[test]
    fn test_pct_defaults() {
        let p = pct();
        assert!(approx_eq(p.min_val, 0.0, 1e-10));
        assert!(approx_eq(p.max_val, 100.0, 1e-10));
        assert_eq!(p.unit_str, "%");
        assert!(approx_eq(p.default_val, 50.0, 1e-10));
    }

    #[test]
    fn test_toggle_defaults() {
        let p = toggle();
        assert!(approx_eq(p.min_val, 0.0, 1e-10));
        assert!(approx_eq(p.max_val, 1.0, 1e-10));
        assert!(approx_eq(p.default_val, 0.0, 1e-10));
    }

    #[test]
    fn test_ratio_defaults() {
        let p = ratio();
        assert!(approx_eq(p.min_val, 1.0, 1e-10));
        assert!(approx_eq(p.max_val, 20.0, 1e-10));
        assert_eq!(p.unit_str, ":1");
        assert!(approx_eq(p.default_val, 4.0, 1e-10));
    }

    #[test]
    fn test_param_custom() {
        let p = param(5.0, 10.0);
        assert!(approx_eq(p.min_val, 5.0, 1e-10));
        assert!(approx_eq(p.max_val, 10.0, 1e-10));
        assert!(approx_eq(p.default_val, 5.0, 1e-10));
        assert_eq!(p.unit_str, "");
    }

    #[test]
    fn test_chaining() {
        let p = freq().min(100.0).max(5000.0).default(440.0);
        assert!(approx_eq(p.min_val, 100.0, 1e-10));
        assert!(approx_eq(p.max_val, 5000.0, 1e-10));
        assert!(approx_eq(p.default_val, 440.0, 1e-10));
        assert_eq!(p.unit_str, "Hz");
        assert_eq!(p.curve_str, "log");
    }
}
