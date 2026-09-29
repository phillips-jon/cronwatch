/// Whether JavaScript's `\s` matches `c`: WhiteSpace and LineTerminator,
/// which is also what `String.prototype.trim` removes.
pub(crate) fn is_space(c: char) -> bool {
    ('\u{2000}'..='\u{200a}').contains(&c)
        || matches!(
            c,
            '\t' | '\n'
                | '\u{0b}'
                | '\u{0c}'
                | '\r'
                | ' '
                | '\u{a0}'
                | '\u{1680}'
                | '\u{2028}'
                | '\u{2029}'
                | '\u{202f}'
                | '\u{205f}'
                | '\u{3000}'
                | '\u{feff}'
        )
}

/// `String.prototype.trim`.
pub(crate) fn trim(s: &str) -> &str {
    s.trim_matches(is_space)
}

/// `String.prototype.trimEnd`.
pub(crate) fn trim_end(s: &str) -> &str {
    s.trim_end_matches(is_space)
}

/// A string's `.length`: its UTF-16 code units.
pub(crate) fn len16(s: &str) -> usize {
    s.chars().map(char::len_utf16).sum()
}

/// `s.slice(start, end)` in UTF-16 code units, with JavaScript's clamping (a
/// negative index counts from the end). A cut through a surrogate pair keeps
/// the lone half, which is written here as U+FFFD, the character it becomes
/// once written out as UTF-8, so a stored or hashed result is the same bytes.
pub(crate) fn slice16(s: &str, start: i64, end: i64) -> String {
    let n = len16(s) as i64;
    let clamp = |i: i64| if i < 0 { (i + n).max(0) } else { i.min(n) };
    let (start, end) = (clamp(start), clamp(end));
    if start >= end {
        return String::new();
    }
    if start == 0 && end == n {
        return s.to_string();
    }
    let mut b = String::new();
    let mut at = 0i64;
    for c in s.chars() {
        let (lo, hi) = (at, at + c.len_utf16() as i64);
        at = hi;
        if hi <= start {
            continue;
        }
        if lo >= end {
            break;
        }
        b.push(if lo >= start && hi <= end { c } else { char::REPLACEMENT_CHARACTER });
    }
    b
}

/// `s.slice(0, n)`.
pub(crate) fn head16(s: &str, n: usize) -> String {
    slice16(s, 0, n as i64)
}

/// `s.slice(s.length - n)`: the last `n` code units.
pub(crate) fn tail16(s: &str, n: usize) -> String {
    let len = len16(s) as i64;
    slice16(s, len - n as i64, len)
}

/// The string as UTF-16 code units, as JavaScript holds it.
pub(crate) fn units(s: &str) -> Vec<u16> {
    s.encode_utf16().collect()
}

/// The text of UTF-16 code units; a lone surrogate becomes U+FFFD, as it does
/// once JavaScript writes it out as UTF-8.
pub(crate) fn from_units(u: &[u16]) -> String {
    char::decode_utf16(u.iter().copied()).map(|r| r.unwrap_or(char::REPLACEMENT_CHARACTER)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lengths_and_cuts_count_utf16() {
        assert_eq!(len16("a😀"), 3);
        assert_eq!(slice16("a😀b", 0, 2), "a\u{fffd}");
        assert_eq!(slice16("a😀b", 2, 4), "\u{fffd}b");
        assert_eq!(slice16("abc", -2, 3), "bc");
        assert_eq!(head16("abc", 10), "abc");
        assert_eq!(tail16("abcdef", 2), "ef");
        assert_eq!(from_units(&[0xd83d]), "\u{fffd}");
        assert_eq!(from_units(&units("x😀")), "x😀");
        assert_eq!(trim("\u{feff} a \u{3000}"), "a");
        assert_eq!(trim_end(" a \n"), " a");
    }
}
