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
    let is_linear = spec.curve_str.as_bytes().len() == 6
        && spec.curve_str.as_bytes()[0] == b'l'
        && spec.curve_str.as_bytes()[1] == b'i'
        && spec.curve_str.as_bytes()[2] == b'n'
        && spec.curve_str.as_bytes()[3] == b'e'
        && spec.curve_str.as_bytes()[4] == b'a'
        && spec.curve_str.as_bytes()[5] == b'r';

    if is_linear {
        s.push_byte(b'}')
    } else {
        let s = s.push_str(r#","curve":""#);
        let s = s.push_str(spec.curve_str);
        let s = s.push_str(r#""}"#);
        s
    }
}
