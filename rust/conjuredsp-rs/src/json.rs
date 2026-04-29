/// Const-fn JSON serialization for parameter metadata.
///
/// Builds a JSON array string from ParamSpec values at compile time.
/// Used internally by the `params!()` macro.

/// Fixed-size buffer for building JSON strings at compile time.
pub struct JsonBuf {
    pub buf: [u8; 4096],
    pub len: usize,
}

impl JsonBuf {
    pub const fn new() -> Self {
        JsonBuf {
            buf: [0; 4096],
            len: 0,
        }
    }

    pub const fn push_byte(mut self, b: u8) -> Self {
        self.buf[self.len] = b;
        self.len += 1;
        self
    }

    pub const fn push_str(mut self, s: &str) -> Self {
        let bytes = s.as_bytes();
        let mut i = 0;
        while i < bytes.len() {
            self.buf[self.len] = bytes[i];
            self.len += 1;
            i += 1;
        }
        self
    }

    /// Write an f64 value as a JSON number string.
    /// Handles integers, simple decimals, and negative values.
    pub const fn push_f64(self, val: f64) -> Self {
        // Handle negative values
        let (s, val) = if val < 0.0 {
            (self.push_byte(b'-'), -val)
        } else {
            (self, val)
        };

        // Split into integer and fractional parts
        let int_part = val as u64;
        let frac_part = ((val - int_part as f64) * 1_000_000.0 + 0.5) as u64;

        // Write integer part
        let s = s.push_u64(int_part);

        // Write fractional part if non-zero
        if frac_part > 0 {
            let s = s.push_byte(b'.');
            // Write fractional digits, trimming trailing zeros
            s.push_frac(frac_part, 6)
        } else {
            // Always write .0 for floating point
            s.push_str(".0")
        }
    }

    const fn push_u64(self, val: u64) -> Self {
        if val == 0 {
            return self.push_byte(b'0');
        }
        // Find the number of digits
        let mut digits = [0u8; 20];
        let mut n = val;
        let mut count = 0;
        while n > 0 {
            digits[count] = (n % 10) as u8 + b'0';
            n /= 10;
            count += 1;
        }
        // Write in reverse order
        let mut s = self;
        let mut i = count;
        while i > 0 {
            i -= 1;
            s = s.push_byte(digits[i]);
        }
        s
    }

    /// Write fractional digits, trimming trailing zeros.
    const fn push_frac(self, frac: u64, total_digits: usize) -> Self {
        // Convert to digit array
        let mut digits = [0u8; 6];
        let mut n = frac;
        let mut i = total_digits;
        while i > 0 {
            i -= 1;
            digits[i] = (n % 10) as u8 + b'0';
            n /= 10;
        }

        // Find last non-zero digit
        let mut last = total_digits;
        while last > 1 {
            if digits[last - 1] != b'0' {
                break;
            }
            last -= 1;
        }

        // Write digits up to last non-zero
        let mut s = self;
        i = 0;
        while i < last {
            s = s.push_byte(digits[i]);
            i += 1;
        }
        s
    }

    /// Convert a SCREAMING_SNAKE_CASE identifier to Title Case.
    /// E.g., "CUTOFF" → "Cutoff", "LOW_GAIN" → "Low Gain".
    pub const fn push_title_case(mut self, name: &str) -> Self {
        let bytes = name.as_bytes();
        let mut i = 0;
        let mut capitalize_next = true;
        while i < bytes.len() {
            let b = bytes[i];
            if b == b'_' {
                self.buf[self.len] = b' ';
                self.len += 1;
                capitalize_next = true;
            } else if capitalize_next {
                self.buf[self.len] = b;
                self.len += 1;
                capitalize_next = false;
            } else {
                // Lowercase
                self.buf[self.len] = if b >= b'A' && b <= b'Z' {
                    b + 32
                } else {
                    b
                };
                self.len += 1;
            }
            i += 1;
        }
        self
    }

    /// Get the built string as a byte slice.
    pub const fn as_bytes(&self) -> &[u8] {
        // Split at len
        let result: &[u8] = &self.buf;
        // We can't use &self.buf[..self.len] in const, so we use split_at
        let (head, _) = result.split_at(self.len);
        head
    }
}

/// Check if a string equals a target via byte comparison (const-compatible).
const fn str_eq(a: &str, b: &str) -> bool {
    let a = a.as_bytes();
    let b = b.as_bytes();
    if a.len() != b.len() {
        return false;
    }
    let mut i = 0;
    while i < a.len() {
        if a[i] != b[i] {
            return false;
        }
        i += 1;
    }
    true
}

/// Write a single ParamSpec as a JSON object into the buffer.
/// `name` is the SCREAMING_SNAKE_CASE identifier from the macro.
pub const fn write_param_json(buf: JsonBuf, name: &str, spec: &crate::ParamSpec) -> JsonBuf {
    let s = buf.push_str(r#"{"name":""#);
    let s = s.push_title_case(name);
    let s = s.push_str(r#"","min":"#);
    let s = s.push_f64(spec.min_val);
    let s = s.push_str(r#","max":"#);
    let s = s.push_f64(spec.max_val);
    let s = s.push_str(r#","unit":""#);
    let s = s.push_str(spec.unit_str);
    let s = s.push_str(r#"","default":"#);
    let s = s.push_f64(spec.default_val);

    // Only include curve if non-linear
    let is_linear = str_eq(spec.curve_str, "linear");

    let s = if is_linear {
        s
    } else {
        let s = s.push_str(r#","curve":""#);
        let s = s.push_str(spec.curve_str);
        s.push_byte(b'"')
    };

    // Include style if not "slider" (default)
    let is_slider = str_eq(spec.style_str, "slider");

    let s = if is_slider {
        s
    } else {
        let s = s.push_str(r#","style":""#);
        let s = s.push_str(spec.style_str);
        s.push_byte(b'"')
    };

    // Include options for choice style
    let s = if spec.options.len() > 0 {
        let s = s.push_str(r#","options":["#);
        let mut s = s;
        let mut i = 0;
        while i < spec.options.len() {
            if i > 0 {
                s = s.push_byte(b',');
            }
            s = s.push_byte(b'"');
            s = s.push_str(spec.options[i]);
            s = s.push_byte(b'"');
            i += 1;
        }
        s.push_byte(b']')
    } else {
        s
    };

    s.push_byte(b'}')
}

/// Write a single TelemetrySpec as a JSON object into the buffer.
/// Schema: `{"name": "<identifier>", "unit": "<unit>", "shape": "scalar"|"vector"}`.
/// The name is the verbatim identifier from the `telemetry!()` macro
/// (SCREAMING_SNAKE_CASE in idiomatic Rust) — passed through with no
/// canonicalization, so JS reads `frame.telemetry["PEAK_DB"]` to
/// match.
///
/// Differs deliberately from `write_param_json`, which title-cases:
/// params surface in DAW automation lanes ("Low Gain"), so the
/// canonicalization earns its cost there. Telemetry is JS-internal —
/// the JSON `name` field IS the JS lookup key — and predictability +
/// not-mangling-acronyms (DB / RMS / FFT / NAM / GR) wins. Authors
/// writing a UI that targets both backends accept that
/// `PEAK_DB` (Rust) and `peak_db` (Python) are different keys; the
/// canonical pattern is `frame.telemetry["PEAK_DB"] ?? frame.telemetry["peak_db"]`.
pub const fn write_telemetry_json(
    buf: JsonBuf,
    name: &str,
    spec: &crate::TelemetrySpec,
) -> JsonBuf {
    let s = buf.push_str(r#"{"name":""#);
    let s = s.push_str(name);
    let s = s.push_str(r#"","unit":""#);
    let s = s.push_str(spec.unit_str);
    let s = s.push_str(r#"","shape":""#);
    let s = match spec.shape {
        crate::TelemetryShape::Scalar => s.push_str("scalar"),
        crate::TelemetryShape::Vector => s.push_str("vector"),
    };
    s.push_str(r#""}"#)
}

#[cfg(test)]
mod tests {
    extern crate std;
    use super::*;
    use std::string::String;

    fn buf_to_string(buf: &JsonBuf) -> String {
        String::from_utf8(buf.as_bytes().to_vec()).unwrap()
    }

    #[test]
    fn test_new_empty() {
        let buf = JsonBuf::new();
        assert_eq!(buf.len, 0);
    }

    #[test]
    fn test_push_str() {
        let buf = JsonBuf::new().push_str("hello");
        assert_eq!(buf_to_string(&buf), "hello");
    }

    #[test]
    fn test_push_f64_zero() {
        let buf = JsonBuf::new().push_f64(0.0);
        assert_eq!(buf_to_string(&buf), "0.0");
    }

    #[test]
    fn test_push_f64_1_5() {
        let buf = JsonBuf::new().push_f64(1.5);
        assert_eq!(buf_to_string(&buf), "1.5");
    }

    #[test]
    fn test_push_f64_negative() {
        let buf = JsonBuf::new().push_f64(-3.14);
        let s = buf_to_string(&buf);
        assert!(s.starts_with("-3.14"), "expected -3.14..., got {}", s);
    }

    #[test]
    fn test_push_f64_1000() {
        let buf = JsonBuf::new().push_f64(1000.0);
        assert_eq!(buf_to_string(&buf), "1000.0");
    }

    #[test]
    fn test_push_f64_0_1() {
        let buf = JsonBuf::new().push_f64(0.1);
        assert_eq!(buf_to_string(&buf), "0.1");
    }

    #[test]
    fn test_push_title_case_single_word() {
        let buf = JsonBuf::new().push_title_case("CUTOFF");
        assert_eq!(buf_to_string(&buf), "Cutoff");
    }

    #[test]
    fn test_push_title_case_multi_word() {
        let buf = JsonBuf::new().push_title_case("LOW_GAIN");
        assert_eq!(buf_to_string(&buf), "Low Gain");
    }

    #[test]
    fn test_push_title_case_short() {
        let buf = JsonBuf::new().push_title_case("HI");
        assert_eq!(buf_to_string(&buf), "Hi");
    }

    #[test]
    fn test_write_param_json_linear() {
        let spec = crate::ParamSpec {
            min_val: 0.0,
            max_val: 100.0,
            unit_str: "%",
            default_val: 50.0,
            curve_str: "linear",
            style_str: "slider",
            options: &[],
        };
        let buf = write_param_json(JsonBuf::new(), "MIX", &spec);
        let s = buf_to_string(&buf);
        // Linear curve should NOT include "curve" key
        assert!(!s.contains("curve"), "linear param should omit curve, got: {}", s);
        // Slider style should NOT include "style" key
        assert!(!s.contains("style"), "slider param should omit style, got: {}", s);
        assert!(s.contains(r#""name":"Mix""#), "got: {}", s);
        assert!(s.contains(r#""min":0.0"#), "got: {}", s);
        assert!(s.contains(r#""max":100.0"#), "got: {}", s);
        assert!(s.contains(r#""unit":"%""#), "got: {}", s);
        assert!(s.contains(r#""default":50.0"#), "got: {}", s);
    }

    #[test]
    fn test_write_param_json_log() {
        let spec = crate::ParamSpec {
            min_val: 20.0,
            max_val: 20000.0,
            unit_str: "Hz",
            default_val: 1000.0,
            curve_str: "log",
            style_str: "slider",
            options: &[],
        };
        let buf = write_param_json(JsonBuf::new(), "CUTOFF", &spec);
        let s = buf_to_string(&buf);
        // Log curve should include "curve":"log"
        assert!(s.contains(r#""curve":"log""#), "log param should include curve, got: {}", s);
        assert!(s.contains(r#""name":"Cutoff""#), "got: {}", s);
    }

    #[test]
    fn test_write_param_json_toggle() {
        let spec = crate::toggle();
        let buf = write_param_json(JsonBuf::new(), "BYPASS", &spec);
        let s = buf_to_string(&buf);
        assert!(s.contains(r#""style":"toggle""#), "toggle param should include style, got: {}", s);
        assert!(!s.contains("options"), "toggle should not have options, got: {}", s);
    }

    #[test]
    fn test_write_param_json_integer() {
        let spec = crate::integer(2.0, 6.0).default(4.0);
        let buf = write_param_json(JsonBuf::new(), "STAGES", &spec);
        let s = buf_to_string(&buf);
        assert!(s.contains(r#""style":"integer""#), "integer param should include style, got: {}", s);
        assert!(s.contains(r#""name":"Stages""#), "got: {}", s);
        assert!(s.contains(r#""min":2.0"#), "got: {}", s);
        assert!(s.contains(r#""max":6.0"#), "got: {}", s);
        assert!(s.contains(r#""default":4.0"#), "got: {}", s);
        assert!(!s.contains("options"), "integer should not have options, got: {}", s);
        assert!(!s.contains("curve"), "integer (linear) should omit curve, got: {}", s);
    }

    #[test]
    fn test_write_telemetry_json_scalar_no_unit() {
        let spec = crate::scalar_telemetry();
        let buf = write_telemetry_json(JsonBuf::new(), "ENV_LEVEL", &spec);
        let s = buf_to_string(&buf);
        // Pass-through: identifier emitted verbatim. JS reads
        // frame.telemetry["ENV_LEVEL"]. Mangled forms like "Env Level"
        // are deliberately NOT produced — telemetry doesn't have a
        // DAW display surface, and acronyms in the macro identifier
        // (DB, GR, RMS) survive unscathed.
        assert_eq!(s, r#"{"name":"ENV_LEVEL","unit":"","shape":"scalar"}"#);
    }

    #[test]
    fn test_write_telemetry_json_scalar_with_unit() {
        let spec = crate::scalar_telemetry().unit("dB");
        let buf = write_telemetry_json(JsonBuf::new(), "GR_DB", &spec);
        let s = buf_to_string(&buf);
        assert_eq!(s, r#"{"name":"GR_DB","unit":"dB","shape":"scalar"}"#);
    }

    #[test]
    fn test_write_telemetry_json_vector() {
        let spec = crate::vector_telemetry();
        let buf = write_telemetry_json(JsonBuf::new(), "WAVE", &spec);
        let s = buf_to_string(&buf);
        assert_eq!(s, r#"{"name":"WAVE","unit":"","shape":"vector"}"#);
    }

    #[test]
    fn test_write_param_json_choice() {
        let spec = crate::choice(&["Low", "Mid", "High"]).default(1.0);
        let buf = write_param_json(JsonBuf::new(), "MODE", &spec);
        let s = buf_to_string(&buf);
        assert!(s.contains(r#""style":"choice""#), "choice param should include style, got: {}", s);
        assert!(s.contains(r#""options":["Low","Mid","High"]"#), "choice should have options, got: {}", s);
        assert!(s.contains(r#""max":2.0"#), "max should be len-1, got: {}", s);
    }
}
