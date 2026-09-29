/// `String(n)`: the shortest digits that read back as `n`, in plain notation
/// from 1e-7 up to 1e21 and exponential notation outside it, as
/// `Number.prototype.toString` writes them.
pub(crate) fn format_number(n: f64) -> String {
    if n.is_nan() {
        return "NaN".into();
    }
    if n.is_infinite() {
        return if n > 0.0 { "Infinity".into() } else { "-Infinity".into() };
    }
    if n == 0.0 {
        return "0".into();
    }
    let sign = if n < 0.0 { "-" } else { "" };
    // The shortest round-tripping digits and the decimal exponent, as
    // ECMAScript's Number::toString defines them: digits d1...dk with the
    // value d1.d2...dk * 10^(e). Rust's `{:e}` is the shortest form.
    let text = format!("{:e}", n.abs());
    let (mantissa, exp) = text.split_once('e').unwrap_or((&text, "0"));
    let digits: String = mantissa.chars().filter(|&c| c != '.').collect();
    let e: i64 = exp.parse().unwrap_or(0);
    let k = digits.len() as i64;
    let point = e + 1; // ECMAScript's n: the digits are d1...dk * 10^(n-k)
    let mut b = String::from(sign);
    if k <= point && point <= 21 {
        b.push_str(&digits);
        b.push_str(&"0".repeat((point - k) as usize));
    } else if 0 < point && point <= 21 {
        b.push_str(&digits[..point as usize]);
        b.push('.');
        b.push_str(&digits[point as usize..]);
    } else if -6 < point && point <= 0 {
        b.push_str("0.");
        b.push_str(&"0".repeat((-point) as usize));
        b.push_str(&digits);
    } else {
        b.push_str(&digits[..1]);
        if k > 1 {
            b.push('.');
            b.push_str(&digits[1..]);
        }
        b.push('e');
        if point >= 1 {
            b.push('+');
        }
        b.push_str(&(point - 1).to_string());
    }
    b
}

/// `Number.isInteger`.
pub(crate) fn is_integer(n: f64) -> bool {
    n.is_finite() && n == n.trunc()
}

/// `Math.floor(a / b)` for whole numbers, `b > 0`.
pub(crate) fn floor_div(a: i64, b: i64) -> i64 {
    a.div_euclid(b)
}

/// A modulo whose result has the sign of `b`, as Python's `%` has it.
pub(crate) fn modulo(a: i64, b: i64) -> i64 {
    let m = a % b;
    if m != 0 && (m < 0) != (b < 0) { m + b } else { m }
}

/// A JavaScript number as an `i64`, as the ports hold times: truncated,
/// NaN as 0, and held at the ends of the range.
pub(crate) fn to_i64(n: f64) -> i64 {
    if n.is_nan() { 0 } else { n as i64 }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn numbers_print_as_javascript_prints_them() {
        let cases: &[(f64, &str)] = &[
            (2.0, "2"),
            (-2.5, "-2.5"),
            (0.1, "0.1"),
            (1e-7, "1e-7"),
            (1.5e-7, "1.5e-7"),
            (0.000001, "0.000001"),
            (1e21, "1e+21"),
            (1e20, "100000000000000000000"),
            (123456789012345680000.0, "123456789012345680000"),
            (1.2345678901234568e20, "123456789012345680000"),
            (f64::NAN, "NaN"),
            (f64::INFINITY, "Infinity"),
            (f64::NEG_INFINITY, "-Infinity"),
            (-0.0, "0"),
            (1.7976931348623157e308, "1.7976931348623157e+308"),
            (5e-324, "5e-324"),
            (1234.56785, "1234.56785"),
        ];
        for &(n, want) in cases {
            assert_eq!(format_number(n), want, "{n}");
        }
    }

    #[test]
    fn integers_and_division() {
        assert!(is_integer(3.0));
        assert!(!is_integer(3.5));
        assert!(!is_integer(f64::INFINITY));
        assert_eq!(floor_div(-1, 1000), -1);
        assert_eq!(floor_div(1999, 1000), 1);
        assert_eq!(modulo(-1, 12), 11);
    }
}
