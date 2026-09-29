//! What the dashboard's pages need to write values the way the SDK's
//! templates do (routes/escape.ts and JavaScript itself): `escapeHtml`,
//! `escapeName`, `String(value)`, `toFixed`, `Math.round` and
//! `encodeURIComponent`, and how a header's bytes are read and a secret
//! compared.

use crate::format::js_text;
use crate::js::{self, Value};

/// `escapeHtml` for text: `& < > " '` escaped. Every string a page shows
/// goes through it.
pub(crate) fn escape_html(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 8);
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            c => out.push(c),
        }
    }
    out
}

/// `escapeHtml(value ?? "")` for a JSON value: `String(value)`, with an
/// absent field and `null` as nothing.
pub(crate) fn escape_value(v: Option<&Value>) -> String {
    match v {
        None | Some(Value::Null) => String::new(),
        Some(v) => escape_html(&js_text(Some(v))),
    }
}

fn is_separator(c: u8) -> bool {
    matches!(c, b'_' | b':' | b'.' | b'/' | b'-')
}

/// `escapeName`: a job name shown as text, with `<wbr>` after each run of
/// `_ : . / -` that something else follows, so a long name wraps at its
/// separators. Only for text, never an attribute, a URL or a title.
pub(crate) fn escape_name(s: &str) -> String {
    let text = escape_html(s);
    let bytes = text.as_bytes();
    let mut out = String::with_capacity(text.len() + 16);
    let mut from = 0;
    for i in 0..bytes.len() {
        if is_separator(bytes[i]) && i + 1 < bytes.len() && !is_separator(bytes[i + 1]) {
            out.push_str(&text[from..=i]);
            out.push_str("<wbr>");
            from = i + 1;
        }
    }
    out.push_str(&text[from..]);
    out
}

/// `String(n)` for a number.
pub(crate) fn num(n: impl Into<f64>) -> String {
    js::format_number(n.into())
}

/// `String(n)` for a count.
pub(crate) fn count(n: usize) -> String {
    js::format_number(n as f64)
}

/// `Number.prototype.toFixed`: the decimal nearest the exact value of the
/// double, a half rounded away from zero (Rust's own formatting rounds a
/// half to even). Worked out in whole numbers: a double below 1e21 times
/// 10^digits fits in a `u128`.
pub(crate) fn to_fixed(x: f64, digits: u32) -> String {
    if !x.is_finite() || x.abs() >= 1e21 {
        return js::format_number(x);
    }
    let digits = digits.min(10);
    let bits = x.abs().to_bits();
    let exponent = ((bits >> 52) & 0x7ff) as i32;
    let fraction = bits & ((1u64 << 52) - 1);
    let (mantissa, e) = if exponent == 0 { (fraction, -1074) } else { (fraction | (1u64 << 52), exponent - 1075) };
    let scaled = u128::from(mantissa) * 5u128.pow(digits);
    let k = e + digits as i32;
    let n: u128 = if k >= 0 {
        scaled << k
    } else {
        let shift = -k;
        if shift >= 127 {
            0
        } else {
            let q = scaled >> shift;
            let r = scaled & ((1u128 << shift) - 1);
            q + u128::from(r >= 1u128 << (shift - 1))
        }
    };
    let mut text = n.to_string();
    let d = digits as usize;
    if d > 0 {
        if text.len() <= d {
            text = format!("{}{text}", "0".repeat(d + 1 - text.len()));
        }
        text.insert(text.len() - d, '.');
    }
    if x < 0.0 { format!("-{text}") } else { text }
}

/// `Math.round`: the nearest whole number, a half rounded up.
pub(crate) fn js_round(x: f64) -> f64 {
    if !x.is_finite() {
        return x;
    }
    let f = x.floor();
    if x - f >= 0.5 { f + 1.0 } else { f }
}

const HEX: &[u8; 16] = b"0123456789ABCDEF";

/// `encodeURIComponent`.
pub(crate) fn encode_uri_component(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for &c in s.as_bytes() {
        if c.is_ascii_alphanumeric() || b"-_.!~*'()".contains(&c) {
            out.push(c as char);
        } else {
            out.push('%');
            out.push(HEX[(c >> 4) as usize] as char);
            out.push(HEX[(c & 15) as usize] as char);
        }
    }
    out
}

/// Text read from the wire as fetch's `Headers` read it: each byte one
/// character.
pub(crate) fn latin1(bytes: &[u8]) -> String {
    bytes.iter().map(|&b| b as char).collect()
}

/// Compares two secrets without stopping at the first character that
/// differs, over UTF-16 code units as the SDK compares them.
pub(crate) fn constant_time_eq(a: &str, b: &str) -> bool {
    let (ua, ub) = (js::units(a), js::units(b));
    if ua.len() != ub.len() {
        return false;
    }
    ua.iter().zip(&ub).fold(0u16, |diff, (x, y)| diff | (x ^ y)) == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn to_fixed_rounds_a_half_away_from_zero_on_the_exact_value() {
        let cases: &[(f64, u32, &str)] = &[
            (0.25, 1, "0.3"),
            (0.35, 1, "0.3"), // 0.34999999999999997779...
            (1.005, 2, "1.00"),
            (2.5, 0, "3"),
            (-2.5, 0, "-3"),
            (-0.04, 1, "-0.0"),
            (0.0, 1, "0.0"),
            (123.456, 1, "123.5"),
            (0.123456, 4, "0.1235"),
            (1e20, 1, "100000000000000000000.0"),
            (5e-324, 4, "0.0000"),
            (1000.0, 1, "1000.0"),
            (1e21, 1, "1e+21"),
        ];
        for &(x, d, want) in cases {
            assert_eq!(to_fixed(x, d), want, "{x}.toFixed({d})");
        }
    }

    #[test]
    fn names_break_after_runs_of_separators() {
        assert_eq!(escape_name("wp:store_sync.inventory--eu"), "wp:<wbr>store_<wbr>sync.<wbr>inventory--<wbr>eu");
        assert_eq!(escape_name("a-"), "a-");
        assert_eq!(escape_name("<a>_b"), "&lt;a&gt;_<wbr>b");
    }

    #[test]
    fn secrets_compare_as_utf16() {
        assert!(constant_time_eq("tok", "tok"));
        assert!(!constant_time_eq("tok", "toK"));
        assert!(!constant_time_eq("é", &latin1("é".as_bytes())));
        assert!(constant_time_eq("é", &latin1(&[0xe9])));
    }
}
