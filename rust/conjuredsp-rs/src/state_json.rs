//! Tiny JSON reader used by the `state!()` macro's typed accessors.
//!
//! Goal: pull a top-level field out of the kernel's STATE JSON buffer and
//! decode it as a fixed-shape value (`i32`, `bool`, `f32`, `[u8; N]`,
//! `[f32; N]`) without dragging `serde` / `serde_json` into the WASM
//! sysroot. The kernel guarantees the buffer is well-formed JSON
//! (`set_state_json_bytes` validates with `serde_json::from_slice`), so
//! this parser only handles the subset of constructs the host could
//! plausibly emit, returns `None` on any deviation, and never panics.
//!
//! Layout the parser expects: `{"key1": <value>, "key2": <value>, ...}`,
//! UTF-8, no nested objects or trailing junk inside values it accepts.
//! Nested arrays of numbers are fine — that's the whole point.

/// Find the value bytes for `key` in a top-level JSON object. Returns
/// `None` if the buffer is not a JSON object, the key isn't present, or
/// any structural surprise trips the parser.
///
/// The returned slice points at the start of the *value* (whatever
/// comes after the key's `:`), not including any leading whitespace.
/// Trailing content (commas, closing `}`, more keys) is left intact —
/// the typed decoders only consume what they need.
pub fn find_value<'a>(buf: &'a [u8], key: &str) -> Option<&'a [u8]> {
    let mut p = 0;
    p = skip_ws(buf, p);
    if p >= buf.len() || buf[p] != b'{' {
        return None;
    }
    p += 1;
    loop {
        p = skip_ws(buf, p);
        if p >= buf.len() {
            return None;
        }
        if buf[p] == b'}' {
            return None;
        }
        // Read a string key.
        let (k, after_key) = read_string(buf, p)?;
        p = skip_ws(buf, after_key);
        if p >= buf.len() || buf[p] != b':' {
            return None;
        }
        p += 1;
        p = skip_ws(buf, p);
        if k == key.as_bytes() {
            return Some(&buf[p..]);
        }
        // Skip the value, then comma-or-close.
        p = skip_value(buf, p)?;
        p = skip_ws(buf, p);
        if p >= buf.len() {
            return None;
        }
        match buf[p] {
            b',' => {
                p += 1;
            }
            b'}' => return None,
            _ => return None,
        }
    }
}

/// Decode an integer at `start` of `buf`. JSON allows scientific notation
/// (`1e3`); we accept it but only for values that round to an integer.
pub fn parse_i64(buf: &[u8]) -> Option<i64> {
    let s = take_number(buf)?;
    let txt = core::str::from_utf8(s).ok()?;
    if let Ok(v) = txt.parse::<i64>() {
        return Some(v);
    }
    // Fallback: try as f64 and round-trip if it's exact.
    let f = txt.parse::<f64>().ok()?;
    if f.is_finite() && f == (f as i64) as f64 {
        return Some(f as i64);
    }
    None
}

/// Decode a finite f64 at the start of `buf`.
pub fn parse_f64(buf: &[u8]) -> Option<f64> {
    let s = take_number(buf)?;
    let txt = core::str::from_utf8(s).ok()?;
    let v = txt.parse::<f64>().ok()?;
    if v.is_finite() {
        Some(v)
    } else {
        None
    }
}

/// Decode `true` / `false` at the start of `buf`.
pub fn parse_bool(buf: &[u8]) -> Option<bool> {
    if buf.starts_with(b"true") {
        Some(true)
    } else if buf.starts_with(b"false") {
        Some(false)
    } else {
        None
    }
}

/// Decode a JSON array of numbers at the start of `buf` into the slice
/// `out`. Returns the number of elements written; on parse failure
/// returns `None`. Elements past `out.len()` are silently dropped (the
/// host has no opinion on the array's expected length, so an over-long
/// state value still decodes the prefix the script asked for).
///
/// `decode` extracts one element from the byte slice — it's called with
/// the bytes starting at the element's first non-whitespace character
/// and must return the decoded value plus the byte length consumed.
pub fn parse_array_into<T, F>(buf: &[u8], out: &mut [T], mut decode: F) -> Option<usize>
where
    F: FnMut(&[u8]) -> Option<(T, usize)>,
{
    let mut p = 0;
    p = skip_ws(buf, p);
    if p >= buf.len() || buf[p] != b'[' {
        return None;
    }
    p += 1;
    p = skip_ws(buf, p);
    let mut written = 0;
    if p < buf.len() && buf[p] == b']' {
        return Some(0);
    }
    loop {
        let (val, used) = decode(&buf[p..])?;
        if written < out.len() {
            out[written] = val;
        }
        written += 1;
        p += used;
        p = skip_ws(buf, p);
        if p >= buf.len() {
            return None;
        }
        match buf[p] {
            b',' => {
                p += 1;
                p = skip_ws(buf, p);
            }
            b']' => return Some(written),
            _ => return None,
        }
    }
}

// ---- internals ----

fn skip_ws(buf: &[u8], mut p: usize) -> usize {
    while p < buf.len() {
        match buf[p] {
            b' ' | b'\t' | b'\n' | b'\r' => p += 1,
            _ => break,
        }
    }
    p
}

/// Read a JSON string starting with `"` at `p`. Returns the unescaped-ish
/// raw bytes (we don't unescape — for STATE keys callers compare against
/// known plain-ASCII identifiers) and the index past the closing quote.
fn read_string(buf: &[u8], p: usize) -> Option<(&[u8], usize)> {
    if p >= buf.len() || buf[p] != b'"' {
        return None;
    }
    let start = p + 1;
    let mut q = start;
    while q < buf.len() {
        match buf[q] {
            b'"' => return Some((&buf[start..q], q + 1)),
            b'\\' => {
                // Skip the escape byte AND the byte it escapes (unicode
                // escapes consume more, but key matching against a plain
                // ASCII identifier just fails — `find_value` returns None
                // in that case rather than producing wrong matches).
                q += 2;
            }
            _ => q += 1,
        }
    }
    None
}

/// Skip a JSON value (object, array, string, number, bool, null) and
/// return the index past it. Used by `find_value` to step over keys it
/// doesn't care about.
fn skip_value(buf: &[u8], p: usize) -> Option<usize> {
    if p >= buf.len() {
        return None;
    }
    match buf[p] {
        b'{' => skip_balanced(buf, p, b'{', b'}'),
        b'[' => skip_balanced(buf, p, b'[', b']'),
        b'"' => Some(read_string(buf, p)?.1),
        b't' | b'f' | b'n' => skip_keyword(buf, p),
        b'-' | b'0'..=b'9' => Some(p + take_number(&buf[p..])?.len()),
        _ => None,
    }
}

fn skip_balanced(buf: &[u8], start: usize, open: u8, close: u8) -> Option<usize> {
    let mut p = start + 1;
    let mut depth = 1usize;
    while p < buf.len() {
        match buf[p] {
            b'"' => {
                p = read_string(buf, p)?.1;
            }
            c if c == open => {
                depth += 1;
                p += 1;
            }
            c if c == close => {
                depth -= 1;
                p += 1;
                if depth == 0 {
                    return Some(p);
                }
            }
            _ => p += 1,
        }
    }
    None
}

fn skip_keyword(buf: &[u8], p: usize) -> Option<usize> {
    if buf[p..].starts_with(b"true") {
        Some(p + 4)
    } else if buf[p..].starts_with(b"false") {
        Some(p + 5)
    } else if buf[p..].starts_with(b"null") {
        Some(p + 4)
    } else {
        None
    }
}

/// Return the slice of `buf` covering one JSON number starting at index
/// 0. Caller checks the prefix is `-` or a digit.
fn take_number(buf: &[u8]) -> Option<&[u8]> {
    let mut q = 0;
    if q < buf.len() && buf[q] == b'-' {
        q += 1;
    }
    let digits_start = q;
    while q < buf.len() && buf[q].is_ascii_digit() {
        q += 1;
    }
    if q == digits_start {
        return None;
    }
    if q < buf.len() && buf[q] == b'.' {
        q += 1;
        while q < buf.len() && buf[q].is_ascii_digit() {
            q += 1;
        }
    }
    if q < buf.len() && (buf[q] == b'e' || buf[q] == b'E') {
        q += 1;
        if q < buf.len() && (buf[q] == b'+' || buf[q] == b'-') {
            q += 1;
        }
        let exp_start = q;
        while q < buf.len() && buf[q].is_ascii_digit() {
            q += 1;
        }
        if q == exp_start {
            return None;
        }
    }
    Some(&buf[..q])
}

/// Element decoder for `parse_array_into` over `i32`-shaped JSON numbers.
pub fn decode_i32(buf: &[u8]) -> Option<(i32, usize)> {
    let s = take_number(buf)?;
    let txt = core::str::from_utf8(s).ok()?;
    let v: i32 = txt
        .parse::<i32>()
        .ok()
        .or_else(|| txt.parse::<i64>().ok().and_then(|n| i32::try_from(n).ok()))
        .or_else(|| {
            let f = txt.parse::<f64>().ok()?;
            if f.is_finite() && f == (f as i32) as f64 {
                Some(f as i32)
            } else {
                None
            }
        })?;
    Some((v, s.len()))
}

/// Element decoder for `parse_array_into` over `u8`-shaped JSON numbers.
/// Out-of-range values fail the whole parse so the caller can decide
/// whether to fall back to a default array.
pub fn decode_u8(buf: &[u8]) -> Option<(u8, usize)> {
    let (v, n) = decode_i32(buf)?;
    let v = u8::try_from(v).ok()?;
    Some((v, n))
}

/// Element decoder for `parse_array_into` over `f32`-shaped JSON numbers.
pub fn decode_f32(buf: &[u8]) -> Option<(f32, usize)> {
    let s = take_number(buf)?;
    let txt = core::str::from_utf8(s).ok()?;
    let v = txt.parse::<f32>().ok()?;
    if v.is_finite() {
        Some((v, s.len()))
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    extern crate std;
    use super::*;

    #[test]
    fn finds_simple_int() {
        let buf = br#"{"a": 42, "b": 7}"#;
        let v = find_value(buf, "a").unwrap();
        assert_eq!(parse_i64(v), Some(42));
        let v = find_value(buf, "b").unwrap();
        assert_eq!(parse_i64(v), Some(7));
    }

    #[test]
    fn finds_value_after_skipped_object_and_array() {
        let buf = br#"{"obj":{"x":1,"y":2},"arr":[1,2,3],"target":-9}"#;
        let v = find_value(buf, "target").unwrap();
        assert_eq!(parse_i64(v), Some(-9));
    }

    #[test]
    fn missing_key_returns_none() {
        let buf = br#"{"a":1}"#;
        assert!(find_value(buf, "b").is_none());
    }

    #[test]
    fn malformed_input_returns_none() {
        assert!(find_value(b"not json", "a").is_none());
        assert!(find_value(b"{", "a").is_none());
        assert!(find_value(b"{\"a\":}", "a").is_some()); // value will fail to decode
    }

    #[test]
    fn parses_bool() {
        let buf = br#"{"on": true, "off": false}"#;
        assert_eq!(parse_bool(find_value(buf, "on").unwrap()), Some(true));
        assert_eq!(parse_bool(find_value(buf, "off").unwrap()), Some(false));
    }

    #[test]
    fn parses_f64_basic() {
        let buf = br#"{"x": 1.5, "y": -3.25, "z": 1e3}"#;
        assert_eq!(parse_f64(find_value(buf, "x").unwrap()), Some(1.5));
        assert_eq!(parse_f64(find_value(buf, "y").unwrap()), Some(-3.25));
        assert_eq!(parse_f64(find_value(buf, "z").unwrap()), Some(1000.0));
    }

    #[test]
    fn parses_array_into_u8() {
        let buf = br#"{"pat": [1,2,255,0,7]}"#;
        let v = find_value(buf, "pat").unwrap();
        let mut out = [0u8; 5];
        let n = parse_array_into(v, &mut out, decode_u8).unwrap();
        assert_eq!(n, 5);
        assert_eq!(out, [1, 2, 255, 0, 7]);
    }

    #[test]
    fn parse_array_partial_fill_when_out_smaller() {
        let buf = br#"{"pat": [1,2,3,4,5,6,7,8]}"#;
        let v = find_value(buf, "pat").unwrap();
        let mut out = [0u8; 3];
        let n = parse_array_into(v, &mut out, decode_u8).unwrap();
        // n is the total element count seen, even though we only stored
        // the first 3 — lets the caller know whether the source was the
        // expected length.
        assert_eq!(n, 8);
        assert_eq!(out, [1, 2, 3]);
    }

    #[test]
    fn parses_empty_array() {
        let buf = br#"{"pat": []}"#;
        let v = find_value(buf, "pat").unwrap();
        let mut out = [9u8; 4];
        let n = parse_array_into(v, &mut out, decode_u8).unwrap();
        assert_eq!(n, 0);
        // Untouched elements stay at their initial value.
        assert_eq!(out, [9, 9, 9, 9]);
    }

    #[test]
    fn parses_array_into_f32() {
        let buf = br#"{"freqs": [110.0, 220, -1.5, 1e3]}"#;
        let v = find_value(buf, "freqs").unwrap();
        let mut out = [0f32; 4];
        let n = parse_array_into(v, &mut out, decode_f32).unwrap();
        assert_eq!(n, 4);
        assert_eq!(out, [110.0, 220.0, -1.5, 1000.0]);
    }

    #[test]
    fn parse_array_rejects_non_number_element() {
        let buf = br#"{"pat": [1,"oops",3]}"#;
        let v = find_value(buf, "pat").unwrap();
        let mut out = [0u8; 3];
        assert!(parse_array_into(v, &mut out, decode_u8).is_none());
    }

    #[test]
    fn whitespace_tolerated() {
        let buf = br#"   {  "a"  :  42 ,  "b"  : true  }   "#;
        assert_eq!(parse_i64(find_value(buf, "a").unwrap()), Some(42));
        assert_eq!(parse_bool(find_value(buf, "b").unwrap()), Some(true));
    }

    #[test]
    fn nested_arrays_in_skipped_keys_dont_confuse() {
        let buf = br#"{"weird": [[1,2],[3,4]], "answer": 42}"#;
        assert_eq!(
            parse_i64(find_value(buf, "answer").unwrap()),
            Some(42),
        );
    }

    #[test]
    fn embedded_quote_in_skipped_string_doesnt_confuse() {
        let buf = br#"{"label": "has\"quote", "answer": 42}"#;
        assert_eq!(
            parse_i64(find_value(buf, "answer").unwrap()),
            Some(42),
        );
    }
}
