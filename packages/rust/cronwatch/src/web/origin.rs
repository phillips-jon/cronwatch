//! Origins read as the SDK's `new URL(value).origin` reads them, carried
//! over from the Go port's `routes_origin.go`: spaces and control
//! characters around the value and tabs or line breaks in it are dropped,
//! slashes after the scheme may be missing or backslashes, credentials are
//! ignored, the host is lowercased (percent escapes decoded, IPv4 numbers
//! written out, IPv6 compressed, a host outside ASCII written in punycode),
//! and a default port is left out.

use std::net::Ipv6Addr;
use std::str::FromStr;

use crate::js;

use super::request::percent_decode;

/// Why a value is not an origin.
#[derive(Debug, PartialEq)]
pub(crate) enum NotOrigin {
    NotUrl,
    NotHttp,
}

/// The longest host outside ASCII read, in bytes. Punycode takes time in
/// the label's length times its distinct characters, and a `Host` header is
/// anyone's to send: a name no DNS could hold (253 bytes) is refused well
/// past that bound.
const MAX_IDN_HOST: usize = 1024;

/// The origin option as `scheme://host[:port]`, `None` for `""`, or the
/// SDK's error for anything that is not an http or https URL, so a typo
/// fails when the routes are made.
pub(crate) fn configured_origin(value: &str) -> Result<Option<String>, String> {
    if value.is_empty() {
        return Ok(None);
    }
    match read_origin(value) {
        Ok((origin, _)) => Ok(Some(origin)),
        Err(NotOrigin::NotHttp) => Err(format!("routes: origin must be http or https, got {}", js::quote(value))),
        Err(NotOrigin::NotUrl) => Err(format!(
            "routes: origin must be an absolute URL such as \"https://app.example.com\", got {}",
            js::quote(value)
        )),
    }
}

/// `scheme://host[:port]` for text that is a scheme and a bare host, or
/// `None` when it carries a path, credentials, a query, or a fragment, or is
/// not an http or https URL.
pub(crate) fn bare_origin(value: &str) -> Option<String> {
    match read_origin(value) {
        Ok((origin, false)) => Some(origin),
        _ => None,
    }
}

fn is_scheme_start(c: u8) -> bool {
    c.is_ascii_alphabetic()
}

fn is_scheme_char(c: u8) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, b'+' | b'.' | b'-')
}

/// The origin of `value`, and whether anything past the host would show in
/// the URL (a path other than `/`, credentials, a query, or a fragment).
pub(crate) fn read_origin(value: &str) -> Result<(String, bool), NotOrigin> {
    let text: String =
        value.trim_matches(|c: char| c <= '\u{20}').chars().filter(|&c| c != '\t' && c != '\n' && c != '\r').collect();
    let bytes = text.as_bytes();
    let colon = text.find(':').ok_or(NotOrigin::NotUrl)?;
    let scheme = &text[..colon];
    if scheme.is_empty() || !is_scheme_start(bytes[0]) || !scheme.bytes().all(is_scheme_char) {
        return Err(NotOrigin::NotUrl);
    }
    let scheme = scheme.to_ascii_lowercase();
    let default_port = match scheme.as_str() {
        "http" => 80,
        "https" => 443,
        _ => return Err(NotOrigin::NotHttp),
    };
    let rest = text[colon + 1..].trim_start_matches(['/', '\\']);
    let end = rest.find(['/', '\\', '?', '#']).unwrap_or(rest.len());
    let (authority, after) = rest.split_at(end);
    let (userinfo, hostport, has_at) = match authority.rfind('@') {
        Some(i) => (&authority[..i], &authority[i + 1..], true),
        None => ("", authority, false),
    };
    let (host, port) = split_port(hostport)?;
    let host = read_host(host)?;
    let shown = match port {
        Some(p) if p != default_port => format!(":{p}"),
        _ => String::new(),
    };
    let extra = (has_at && !userinfo.is_empty() && userinfo != ":") || past_host(after);
    Ok((format!("{scheme}://{host}{shown}"), extra))
}

fn past_host(after: &str) -> bool {
    let (path, fragment) = match after.split_once('#') {
        Some((p, f)) => (p, Some(f)),
        None => (after, None),
    };
    let (path, query) = path.split_once('?').unwrap_or((path, ""));
    (!path.is_empty() && path != "/" && path != "\\") || !query.is_empty() || fragment.is_some_and(|f| !f.is_empty())
}

/// The host and the port (`None` for none) of `host[:port]`.
fn split_port(authority: &str) -> Result<(&str, Option<u32>), NotOrigin> {
    let (host, rest) = if authority.starts_with('[') {
        let end = authority.find(']').ok_or(NotOrigin::NotUrl)?;
        authority.split_at(end + 1)
    } else if let Some(i) = authority.rfind(':') {
        authority.split_at(i)
    } else {
        (authority, "")
    };
    if rest.is_empty() || rest == ":" {
        return Ok((host, None));
    }
    let digits = rest.strip_prefix(':').ok_or(NotOrigin::NotUrl)?;
    if digits.is_empty() || !digits.bytes().all(|c| c.is_ascii_digit()) {
        return Err(NotOrigin::NotUrl);
    }
    let digits = digits.trim_start_matches('0');
    if digits.len() > 5 {
        return Err(NotOrigin::NotUrl);
    }
    let port: u32 = if digits.is_empty() { 0 } else { digits.parse().map_err(|_| NotOrigin::NotUrl)? };
    if port > 65535 {
        return Err(NotOrigin::NotUrl);
    }
    Ok((host, Some(port)))
}

fn forbidden_host_char(c: char) -> bool {
    c <= '\u{20}' || c == '\u{7f}' || "#%/:<>?@[\\]^|".contains(c)
}

fn read_host(host: &str) -> Result<String, NotOrigin> {
    if host.is_empty() {
        return Err(NotOrigin::NotUrl);
    }
    if let Some(inner) = host.strip_prefix('[') {
        let inner = inner.strip_suffix(']').ok_or(NotOrigin::NotUrl)?;
        if inner.contains('%') {
            return Err(NotOrigin::NotUrl);
        }
        let addr = Ipv6Addr::from_str(inner).map_err(|_| NotOrigin::NotUrl)?;
        return Ok(format!("[{}]", ipv6_text(&addr)));
    }
    let decoded = String::from_utf8(percent_decode(host.as_bytes())).map_err(|_| NotOrigin::NotUrl)?;
    let mut decoded = decoded.to_lowercase();
    if !decoded.is_ascii() {
        if decoded.len() > MAX_IDN_HOST {
            return Err(NotOrigin::NotUrl);
        }
        let mut labels = Vec::new();
        for label in decoded.split('.') {
            if label.is_ascii() {
                labels.push(label.to_string());
            } else {
                labels.push(format!("xn--{}", punycode(label).ok_or(NotOrigin::NotUrl)?));
            }
        }
        decoded = labels.join(".");
    }
    if decoded.is_empty() || decoded.chars().any(forbidden_host_char) {
        return Err(NotOrigin::NotUrl);
    }
    if let Some(v4) = ipv4(&decoded)? {
        return Ok(v4);
    }
    Ok(decoded)
}

/// An IPv6 address as the URL serializer writes it: groups in lowercase
/// hex, the first longest run of two or more zero groups as `::`, and never
/// the dotted form.
fn ipv6_text(addr: &Ipv6Addr) -> String {
    let groups = addr.segments();
    let (mut start, mut length) = (usize::MAX, 0);
    let mut i = 0;
    while i < 8 {
        if groups[i] != 0 {
            i += 1;
            continue;
        }
        let mut j = i;
        while j < 8 && groups[j] == 0 {
            j += 1;
        }
        if j - i > length && j - i > 1 {
            (start, length) = (i, j - i);
        }
        i = j;
    }
    let mut out = String::new();
    let mut i = 0;
    while i < 8 {
        if i == start {
            out.push_str(if i == 0 { "::" } else { ":" });
            i += length;
            continue;
        }
        out.push_str(&format!("{:x}", groups[i]));
        if i < 7 {
            out.push(':');
        }
        i += 1;
    }
    out
}

fn is_decimal(s: &str) -> bool {
    !s.is_empty() && s.bytes().all(|c| c.is_ascii_digit())
}

fn is_hex_label(s: &str) -> bool {
    let b = s.as_bytes();
    b.len() >= 2 && b[0] == b'0' && (b[1] == b'x' || b[1] == b'X') && b[2..].iter().all(u8::is_ascii_hexdigit)
}

fn is_octal_label(s: &str) -> bool {
    let b = s.as_bytes();
    b.len() >= 2 && b[0] == b'0' && b[1..].iter().all(|c| (b'0'..=b'7').contains(c))
}

/// WHATWG's IPv4 parser, for a host whose last label is a number: `127.1`
/// and `0x7f.1` are 127.0.0.1. `None` for a host that is a name.
fn ipv4(host: &str) -> Result<Option<String>, NotOrigin> {
    let mut parts: Vec<&str> = host.split('.').collect();
    if parts.len() > 1 && parts.last() == Some(&"") {
        parts.pop();
    }
    let last = parts[parts.len() - 1];
    if !is_decimal(last) && !is_hex_label(last) {
        return Ok(None);
    }
    if parts.len() > 4 {
        return Err(NotOrigin::NotUrl);
    }
    let numbers = parts.iter().map(|p| ipv4_number(p)).collect::<Result<Vec<f64>, _>>()?;
    let (last_n, init) = numbers.split_last().expect("one part at least");
    if init.iter().any(|&n| n > 255.0) {
        return Err(NotOrigin::NotUrl);
    }
    if *last_n >= 256f64.powi(5 - numbers.len() as i32) {
        return Err(NotOrigin::NotUrl);
    }
    let mut address = *last_n;
    for (i, n) in init.iter().enumerate() {
        address += n * 256f64.powi(3 - i as i32);
    }
    let a = address as u32;
    Ok(Some(format!("{}.{}.{}.{}", a >> 24, (a >> 16) & 255, (a >> 8) & 255, a & 255)))
}

fn ipv4_number(part: &str) -> Result<f64, NotOrigin> {
    if part.is_empty() {
        return Err(NotOrigin::NotUrl);
    }
    if is_hex_label(part) {
        return Ok(if part.len() == 2 { 0.0 } else { parse_big(&part[2..], 16) });
    }
    if is_octal_label(part) {
        return Ok(parse_big(&part[1..], 8));
    }
    if is_decimal(part) && (part == "0" || !part.starts_with('0')) {
        return Ok(parse_big(part, 10));
    }
    Err(NotOrigin::NotUrl)
}

/// Digits too long for an integer read as the float the checks above
/// compare, which is past every limit they test.
fn parse_big(digits: &str, radix: u32) -> f64 {
    u64::from_str_radix(digits, radix).map_or(f64::INFINITY, |n| n as f64)
}

/// RFC 3492's encoding of one label, without the `xn--`.
fn punycode(label: &str) -> Option<String> {
    const BASE: i64 = 36;
    const T_MIN: i64 = 1;
    const T_MAX: i64 = 26;
    const SKEW: i64 = 38;
    const DAMP: i64 = 700;
    let runes: Vec<i64> = label.chars().map(|c| c as i64).collect();
    let mut out: Vec<u8> = runes.iter().filter(|&&r| r < 0x80).map(|&r| r as u8).collect();
    let basic = out.len();
    let mut handled = basic;
    if basic > 0 {
        out.push(b'-');
    }
    let digit = |d: i64| -> u8 { if d < 26 { b'a' + d as u8 } else { b'0' + (d - 26) as u8 } };
    let adapt = |mut delta: i64, points: i64, first: bool| -> i64 {
        delta /= if first { DAMP } else { 2 };
        delta += delta / points;
        let mut k = 0;
        while delta > ((BASE - T_MIN) * T_MAX) / 2 {
            delta /= BASE - T_MIN;
            k += BASE;
        }
        k + (BASE - T_MIN + 1) * delta / (delta + SKEW)
    };
    let (mut n, mut delta, mut bias) = (128i64, 0i64, 72i64);
    while handled < runes.len() {
        let m = runes.iter().copied().filter(|&r| r >= n).min().unwrap_or(i64::from(i32::MAX));
        if (m - n) * (handled as i64 + 1) > i64::from(i32::MAX) - delta {
            return None;
        }
        delta += (m - n) * (handled as i64 + 1);
        n = m;
        for &r in &runes {
            if r < n {
                delta += 1;
            }
            if r == n {
                let mut q = delta;
                let mut k = BASE;
                loop {
                    let t = (k - bias).clamp(T_MIN, T_MAX);
                    if q < t {
                        break;
                    }
                    out.push(digit(t + (q - t) % (BASE - t)));
                    q = (q - t) / (BASE - t);
                    k += BASE;
                }
                out.push(digit(q));
                bias = adapt(delta, handled as i64 + 1, handled == basic);
                delta = 0;
                handled += 1;
            }
        }
        delta += 1;
        n += 1;
    }
    String::from_utf8(out).ok()
}

/// The origin of a request's own URL: its scheme (https when it came over
/// TLS) and `Host`, lowercased and without a default port.
pub(crate) fn request_origin(tls: bool, host: &[u8]) -> String {
    let scheme = if tls { "https" } else { "http" };
    let host = String::from_utf8_lossy(host);
    bare_origin(&format!("{scheme}://{host}")).unwrap_or_else(|| format!("{scheme}://{}", host.to_lowercase()))
}

/// Whether an origin's host is loopback: `localhost`, a name ending in
/// `.localhost`, an IPv4 address in 127.0.0.0/8, or the IPv6 address ::1.
/// Only an origin that reads as one counts: a `Host` header is anyone's to
/// send, and one such as `evil.example/.localhost` or
/// `localhost:1@evil.example` must not put the development token in a link
/// to another host.
pub(crate) fn is_loopback_origin(origin: &str) -> bool {
    let Some(origin) = bare_origin(origin) else {
        return false;
    };
    let origin = origin.as_str();
    let authority = origin.find("://").map_or(origin, |i| &origin[i + 3..]);
    let host = if authority.starts_with('[') {
        authority.find(']').map_or(authority, |end| &authority[..=end])
    } else {
        authority.find(':').map_or(authority, |i| &authority[..i])
    };
    let host = host.to_lowercase();
    if host == "localhost" || host == "[::1]" || host.ends_with(".localhost") {
        return true;
    }
    let Some(rest) = host.strip_prefix("127.") else {
        return false;
    };
    let octets: Vec<&str> = rest.split('.').collect();
    octets.len() == 3
        && octets
            .iter()
            .all(|o| (1..=3).contains(&o.len()) && is_decimal(o) && o.parse::<u32>().is_ok_and(|n| n <= 255))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn origins_read_as_url_origin_reads_them() {
        for (given, want) in [
            (" HTTPS://App.Example.COM:443/x ", "https://app.example.com"),
            ("http:\\\\example.com:8080", "http://example.com:8080"),
            ("http://0x7f.1", "http://127.0.0.1"),
            ("http://[0:0::1]:80", "http://[::1]"),
            ("https://bücher.example", "https://xn--bcher-kva.example"),
            ("http://user:pw@example.com", "http://example.com"),
            ("http://[::ffff:1.2.3.4]", "http://[::ffff:102:304]"),
            ("http://1.2.3.4.", "http://1.2.3.4"),
        ] {
            assert_eq!(configured_origin(given).unwrap().as_deref(), Some(want), "{given}");
        }
        assert_eq!(
            configured_origin("app.example.com").unwrap_err(),
            r#"routes: origin must be an absolute URL such as "https://app.example.com", got "app.example.com""#
        );
        assert_eq!(
            configured_origin("ftp://app.example.com").unwrap_err(),
            r#"routes: origin must be http or https, got "ftp://app.example.com""#
        );
        assert_eq!(configured_origin("").unwrap(), None);
        assert!(configured_origin("http://256.1.1.1.1").is_err());
        assert!(configured_origin("http://a b").is_err());
    }

    #[test]
    fn a_bare_origin_has_nothing_past_its_host() {
        assert_eq!(bare_origin("https://evil.example").as_deref(), Some("https://evil.example"));
        assert_eq!(bare_origin("https://evil.example/"), Some("https://evil.example".into()));
        assert_eq!(bare_origin("https://evil.example/path"), None);
        assert_eq!(bare_origin("https://user@evil.example"), None);
        assert_eq!(bare_origin("https://evil.example?q"), None);
        assert_eq!(bare_origin("javascript://evil.example"), None);
    }

    // The Go port's second audit: a Host header outside ASCII is punycoded
    // only up to 1024 bytes; past that it is not read as a URL at all.
    #[test]
    fn a_long_host_outside_ascii_is_not_read_as_a_url() {
        let long = "é".repeat(600);
        assert_eq!(bare_origin(&format!("http://{long}")), None);
        assert_eq!(request_origin(false, long.as_bytes()), format!("http://{long}"));
        let short = "é".repeat(10);
        assert!(bare_origin(&format!("http://{short}")).unwrap().starts_with("http://xn--"));
    }

    #[test]
    fn loopback_hosts() {
        for yes in [
            "http://localhost:3000",
            "http://app.localhost",
            "http://127.0.0.1",
            "http://127.8.9.10",
            "http://[::1]:3000",
        ] {
            assert!(is_loopback_origin(yes), "{yes}");
        }
        for no in [
            "http://localhost.example",
            "http://128.0.0.1",
            "http://127.0.0.256",
            "http://10.0.0.5:8080",
            "http://[::2]",
            // A Host header that is not a host (the audit).
            "http://evil.example/.localhost",
            "http://localhost:1@evil.example",
            "http://evil.example?.localhost",
            "http://evil.example#.localhost",
        ] {
            assert!(!is_loopback_origin(no), "{no}");
        }
    }
}
