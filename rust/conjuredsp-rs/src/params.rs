/// Specification for a single parameter.
///
/// Use the builder functions ([`freq`], [`db`], [`time_ms`], [`mix`], [`pct`],
/// [`toggle`], [`ratio`], [`choice`], [`param`]) to create specs, then customize with
/// `.min()`, `.max()`, `.default()`, `.unit()`, `.curve()`.
#[derive(Clone, Copy)]
pub struct ParamSpec {
    pub min_val: f64,
    pub max_val: f64,
    pub unit_str: &'static str,
    pub default_val: f64,
    pub curve_str: &'static str,
    /// Display style: "slider" (default), "toggle", or "choice".
    pub style_str: &'static str,
    /// Option labels for "choice" style parameters.
    pub options: &'static [&'static str],
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
///
/// For sub-audio rates (LFOs, tremolo speed, chorus rate), use `lfo_rate()`
/// instead — same Hz unit and log curve, but with sub-audio defaults.
pub const fn freq() -> ParamSpec {
    ParamSpec {
        min_val: 20.0,
        max_val: 20000.0,
        unit_str: "Hz",
        default_val: 1000.0,
        curve_str: "log",
        style_str: "slider",
        options: &[],
    }
}

/// LFO rate parameter (sub-audio Hz) with log curve.
/// Default range: 0.1–20 Hz, default value: 1.0. Use for tremolo / autopan /
/// chorus / vibrato rate parameters. For audio-rate frequencies (filter
/// cutoff, oscillator pitch), use `freq()` instead.
pub const fn lfo_rate() -> ParamSpec {
    ParamSpec {
        min_val: 0.1,
        max_val: 20.0,
        unit_str: "Hz",
        default_val: 1.0,
        curve_str: "log",
        style_str: "slider",
        options: &[],
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
        style_str: "slider",
        options: &[],
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
        style_str: "slider",
        options: &[],
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
        style_str: "slider",
        options: &[],
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
        style_str: "slider",
        options: &[],
    }
}

/// On/off toggle parameter (0 or 1).
/// Default value: 0 (off). Renders as a switch in the UI.
pub const fn toggle() -> ParamSpec {
    ParamSpec {
        min_val: 0.0,
        max_val: 1.0,
        unit_str: "",
        default_val: 0.0,
        curve_str: "linear",
        style_str: "toggle",
        options: &[],
    }
}

/// Enum parameter rendered as a dropdown menu.
///
/// `options` is a slice of label strings. Min is 0, max is len-1.
/// The script receives the selected index as a float (0.0, 1.0, 2.0...).
/// Default value is 0 (first option). Customize with `.default()`.
pub const fn choice(options: &'static [&'static str]) -> ParamSpec {
    ParamSpec {
        min_val: 0.0,
        max_val: options.len() as f64 - 1.0,
        unit_str: "",
        default_val: 0.0,
        curve_str: "linear",
        style_str: "choice",
        options,
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
        style_str: "slider",
        options: &[],
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
        style_str: "slider",
        options: &[],
    }
}

/// Shape of a telemetry slot. Scalar slots publish one f32 per
/// render block; vector slots publish one f32 per audio frame in
/// the current block (length = `frame_count`, harvested into a
/// pre-allocated host-side ring of `max_frames` capacity).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum TelemetryShape {
    Scalar,
    Vector,
}

/// Specification for a single telemetry slot — a value the DSP
/// publishes per-block for the host UI to read via `audio.onFrame`'s
/// `telemetry` field. Use `.unit("dB")` etc. to attach a unit string
/// for display formatting (the same `formatValue` helper that handles
/// param units in cdp-ui.js consumes this).
///
/// Pick the constructor by shape: [`scalar_telemetry`] for a single
/// f32 (meters, GR, RMS), [`vector_telemetry`] for one f32 per audio
/// frame (gain-trajectory plots, NAM activation curves, pre-clipping
/// waveforms).
#[derive(Clone, Copy)]
pub struct TelemetrySpec {
    pub unit_str: &'static str,
    pub shape: TelemetryShape,
}

impl TelemetrySpec {
    /// Set the display unit (e.g., "dB", "Hz", "%").
    pub const fn unit(mut self, unit: &'static str) -> Self {
        self.unit_str = unit;
        self
    }
}

/// Scalar telemetry slot — one f32 per render block. Use for meters,
/// gain-reduction values, RMS readouts. Customize with `.unit("dB")`.
pub const fn scalar_telemetry() -> TelemetrySpec {
    TelemetrySpec { unit_str: "", shape: TelemetryShape::Scalar }
}

/// Vector telemetry slot — one f32 per audio frame in the current
/// render block (length = `frame_count`). Use for per-sample
/// gain-trajectory plots, NAM activation curves, pre-clipping
/// waveform debug views, computed filter responses. Customize with
/// `.unit("dB")`.
pub const fn vector_telemetry() -> TelemetrySpec {
    TelemetrySpec { unit_str: "", shape: TelemetryShape::Vector }
}

/// Integer-valued parameter with explicit min/max.
///
/// Renders as a slider/knob in the in-plugin UI and as a discrete-stepped
/// parameter (`AudioUnitParameterUnit.indexed`) in DAWs, so automation lanes
/// snap to whole numbers. The script receives an exact integer-valued float
/// in `PARAMS_BUF` (e.g. `4.0`).
///
/// Default value is min. Customize with `.unit()`, `.default()`.
pub const fn integer(min: f64, max: f64) -> ParamSpec {
    ParamSpec {
        min_val: min,
        max_val: max,
        unit_str: "",
        default_val: min,
        curve_str: "linear",
        style_str: "integer",
        options: &[],
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
    fn test_lfo_rate_defaults() {
        let p = lfo_rate();
        assert!(approx_eq(p.min_val, 0.1, 1e-10));
        assert!(approx_eq(p.max_val, 20.0, 1e-10));
        assert_eq!(p.unit_str, "Hz");
        assert!(approx_eq(p.default_val, 1.0, 1e-10));
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
        assert_eq!(p.style_str, "toggle");
    }

    #[test]
    fn test_choice_defaults() {
        let p = choice(&["Low", "Mid", "High"]);
        assert!(approx_eq(p.min_val, 0.0, 1e-10));
        assert!(approx_eq(p.max_val, 2.0, 1e-10));
        assert!(approx_eq(p.default_val, 0.0, 1e-10));
        assert_eq!(p.style_str, "choice");
        assert_eq!(p.options, &["Low", "Mid", "High"]);
    }

    #[test]
    fn test_choice_with_default() {
        let p = choice(&["1/1", "1/2", "1/4", "1/8"]).default(2.0);
        assert!(approx_eq(p.max_val, 3.0, 1e-10));
        assert!(approx_eq(p.default_val, 2.0, 1e-10));
        assert_eq!(p.style_str, "choice");
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
    fn test_integer_defaults() {
        let p = integer(2.0, 6.0);
        assert!(approx_eq(p.min_val, 2.0, 1e-10));
        assert!(approx_eq(p.max_val, 6.0, 1e-10));
        assert!(approx_eq(p.default_val, 2.0, 1e-10));
        assert_eq!(p.unit_str, "");
        assert_eq!(p.style_str, "integer");
        assert_eq!(p.curve_str, "linear");
        assert!(p.options.is_empty());
    }

    #[test]
    fn test_integer_with_default_and_unit() {
        let p = integer(1.0, 16.0).default(8.0).unit("bits");
        assert!(approx_eq(p.min_val, 1.0, 1e-10));
        assert!(approx_eq(p.max_val, 16.0, 1e-10));
        assert!(approx_eq(p.default_val, 8.0, 1e-10));
        assert_eq!(p.unit_str, "bits");
        assert_eq!(p.style_str, "integer");
    }

    #[test]
    fn test_scalar_telemetry_default_unit() {
        let t = scalar_telemetry();
        assert_eq!(t.unit_str, "");
        assert_eq!(t.shape, TelemetryShape::Scalar);
    }

    #[test]
    fn test_scalar_telemetry_with_unit() {
        let t = scalar_telemetry().unit("dB");
        assert_eq!(t.unit_str, "dB");
        assert_eq!(t.shape, TelemetryShape::Scalar);
    }

    #[test]
    fn test_vector_telemetry_default_unit() {
        let t = vector_telemetry();
        assert_eq!(t.unit_str, "");
        assert_eq!(t.shape, TelemetryShape::Vector);
    }

    #[test]
    fn test_vector_telemetry_with_unit() {
        let t = vector_telemetry().unit("");
        assert_eq!(t.unit_str, "");
        assert_eq!(t.shape, TelemetryShape::Vector);
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
