//! Reading a request the way the SDK's routes read a fetch `Request`,
//! carried over from the Go port's `routes_request.go`: the path as the URL
//! parser leaves it, the query as `URLSearchParams` parses it, headers as
//! `Headers.get` joins them, and the body as `request.json()` and
//! `request.formData()` read it.

use std::borrow::Cow;

use crate::format::js_text;
use crate::js::{self, Value};

use super::{Body, BodyError, MAX_BODY, Request};

/// A request header as fetch's `Headers.get` gives it: every value joined
/// with `, ` (a cookie's with `; `, as HTTP/2 sends each cookie apart), or
/// `None` when there is none.
pub(crate) fn header<'a>(req: &'a Request, name: &str) -> Option<Cow<'a, [u8]>> {
    let mut values = req.headers.iter().filter(|(n, _)| n.eq_ignore_ascii_case(name)).map(|(_, v)| v.as_slice());
    let first = values.next()?;
    let Some(second) = values.next() else {
        return Some(Cow::Borrowed(first));
    };
    let sep: &[u8] = if name.eq_ignore_ascii_case("cookie") { b"; " } else { b", " };
    let mut out = first.to_vec();
    for v in std::iter::once(second).chain(values) {
        out.extend_from_slice(sep);
        out.extend_from_slice(v);
    }
    Some(Cow::Owned(out))
}

/// The path and query the client sent. A target in the absolute form a
/// proxy is sent starts its path after the host; a fragment is dropped.
pub(crate) fn request_target(target: &str) -> (String, String) {
    let mut target = target;
    if !target.starts_with('/') {
        if let Some(i) = target.find("://") {
            let rest = &target[i + 3..];
            target = rest.find(['/', '?']).map_or("/", |j| &rest[j..]);
        }
    }
    let (path, query) = target.split_once('?').unwrap_or((target, ""));
    let path = path.split_once('#').map_or(path, |(p, _)| p);
    let query = query.split_once('#').map_or(query, |(q, _)| q);
    let path = if path.is_empty() || path == "*" { "/" } else { path };
    (path.to_string(), query.to_string())
}

/// Whether the URL parser leaves `c` in a path as it is: the path
/// percent-encode set is C0 controls, space, `" # < > ? ` { }` and
/// everything past `~`.
fn path_safe(c: u8) -> bool {
    c > 0x20 && c < 0x7f && !b"\"#<>?`{}".contains(&c)
}

const HEX: &[u8; 16] = b"0123456789ABCDEF";

/// A path as `new URL()` leaves it for an http URL: backslashes read as
/// slashes, characters outside the path set escaped, and `.` and `..`
/// segments (written plainly or as `%2e`) resolved.
pub(crate) fn normalize_path(raw: &str) -> String {
    let mut b = String::with_capacity(raw.len());
    for &c in raw.as_bytes() {
        if c == b'\\' {
            b.push('/');
        } else if path_safe(c) || c == b'%' {
            b.push(c as char);
        } else {
            b.push('%');
            b.push(HEX[(c >> 4) as usize] as char);
            b.push(HEX[(c & 15) as usize] as char);
        }
    }
    let trimmed = b.strip_prefix('/').unwrap_or(&b);
    let segments: Vec<&str> = trimmed.split('/').collect();
    let mut out: Vec<&str> = Vec::new();
    for (i, s) in segments.iter().enumerate() {
        let last = i == segments.len() - 1;
        match s.to_ascii_lowercase().as_str() {
            "." | "%2e" => {
                if last {
                    out.push("");
                }
            }
            ".." | ".%2e" | "%2e." | "%2e%2e" => {
                out.pop();
                if last {
                    out.push("");
                }
            }
            _ => out.push(s),
        }
    }
    format!("/{}", out.join("/"))
}

/// The path under the base, without a trailing slash.
pub(crate) fn strip_base(pathname: &str, base: &str) -> String {
    let path = pathname.strip_prefix(base).unwrap_or(pathname);
    let path = if path.is_empty() { "/" } else { path };
    if path.len() > 1 && path.ends_with('/') { path[..path.len() - 1].to_string() } else { path.to_string() }
}

/// `decodeURIComponent`, or `None` where it would throw: an escape that is
/// not one, or bytes that are not UTF-8.
pub(crate) fn safe_decode(s: &str) -> Option<String> {
    let b = s.as_bytes();
    for i in 0..b.len() {
        if b[i] == b'%' && (i + 2 >= b.len() || !b[i + 1].is_ascii_hexdigit() || !b[i + 2].is_ascii_hexdigit()) {
            return None;
        }
    }
    String::from_utf8(percent_decode(b)).ok()
}

fn hex_value(c: u8) -> u8 {
    match c {
        b'0'..=b'9' => c - b'0',
        b'a'..=b'f' => c - b'a' + 10,
        _ => c - b'A' + 10,
    }
}

/// Decodes every `%XX`, leaving anything else as it is.
pub(crate) fn percent_decode(s: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(s.len());
    let mut i = 0;
    while i < s.len() {
        if s[i] == b'%' && i + 2 < s.len() && s[i + 1].is_ascii_hexdigit() && s[i + 2].is_ascii_hexdigit() {
            out.push((hex_value(s[i + 1]) << 4) | hex_value(s[i + 2]));
            i += 3;
            continue;
        }
        out.push(s[i]);
        i += 1;
    }
    out
}

/// `application/x-www-form-urlencoded` parsing as `URLSearchParams` does
/// it: `+` is a space, an escape that is not one is kept as written, and
/// bytes that are not UTF-8 become U+FFFD.
pub(crate) fn parse_form(text: &[u8]) -> Vec<(String, String)> {
    text.split(|&c| c == b'&')
        .filter(|part| !part.is_empty())
        .map(|part| {
            let (name, value) = match part.iter().position(|&c| c == b'=') {
                Some(i) => (&part[..i], &part[i + 1..]),
                None => (part, &[][..]),
            };
            (form_decode(name), form_decode(value))
        })
        .collect()
}

fn form_decode(s: &[u8]) -> String {
    let spaced: Vec<u8> = s.iter().map(|&c| if c == b'+' { b' ' } else { c }).collect();
    String::from_utf8_lossy(&percent_decode(&spaced)).into_owned()
}

/// The `application/x-www-form-urlencoded` serializer `URLSearchParams`
/// writes with.
pub(crate) fn form_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for &c in s.as_bytes() {
        if c.is_ascii_alphanumeric() || matches!(c, b'*' | b'-' | b'.' | b'_') {
            out.push(c as char);
        } else if c == b' ' {
            out.push('+');
        } else {
            out.push('%');
            out.push(HEX[(c >> 4) as usize] as char);
            out.push(HEX[(c & 15) as usize] as char);
        }
    }
    out
}

/// `URLSearchParams#get`: the first value, or `None`.
pub(crate) fn param<'a>(pairs: &'a [(String, String)], name: &str) -> Option<&'a str> {
    pairs.iter().find(|(n, _)| n == name).map(|(_, v)| v.as_str())
}

/// A body past the cap.
pub(crate) struct TooLarge;

/// Reads a body up to `MAX_BODY`, or `TooLarge` past it (by its length, or
/// once more than that has arrived). A body that could not be read to its
/// end (the client went away, a read deadline) is none, as the SDK's
/// `readBody` has it, never the part that arrived: `for=7d` cut short is
/// `for=7`, a silence of 7 ms.
pub(crate) async fn read_limited(body: Body) -> Result<Vec<u8>, TooLarge> {
    match body.read(MAX_BODY).await {
        Ok(data) => Ok(data),
        Err(BodyError::TooLarge) => Err(TooLarge),
        Err(BodyError::Failed(_)) => Ok(Vec::new()),
    }
}

/// A field of a request's form or JSON object, as `String(value)` gives it
/// in JavaScript; `None` for anything else, or a body that cannot be read
/// as its type says. The last of several fields of one name wins, as
/// `Object.fromEntries` has it.
pub(crate) fn body_field(content_type: &str, data: &[u8], name: &str) -> Option<String> {
    if content_type.contains("application/json") {
        let text = String::from_utf8_lossy(data);
        let text = text.strip_prefix('\u{feff}').unwrap_or(&text);
        return match js::parse(text).ok()? {
            Value::Object(o) => o.get(name).map(|v| js_text(Some(v))),
            Value::Array(list) => {
                let i = js::array_index(name)? as usize;
                list.get(i).map(|v| js_text(Some(v)))
            }
            _ => None,
        };
    }
    if content_type.contains("multipart/form-data") {
        return multipart_fields(content_type, data)?.into_iter().rev().find(|(n, _)| n == name).map(|(_, v)| v);
    }
    if content_type.contains("application/x-www-form-urlencoded") {
        return parse_form(data).into_iter().rev().find(|(n, _)| n == name).map(|(_, v)| v);
    }
    None
}

/// A media type's parameter, unquoted, its name matched without regard to
/// case.
fn media_param(content_type: &str, name: &str) -> Option<String> {
    for part in content_type.split(';').skip(1) {
        let Some((k, v)) = part.split_once('=') else {
            continue;
        };
        if !k.trim().eq_ignore_ascii_case(name) {
            continue;
        }
        let v = v.trim();
        return Some(unquote(v));
    }
    None
}

fn unquote(v: &str) -> String {
    let Some(inner) = v.strip_prefix('"').and_then(|s| s.strip_suffix('"')) else {
        return v.to_string();
    };
    let mut out = String::new();
    let mut chars = inner.chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            if let Some(next) = chars.next() {
                out.push(next);
            }
        } else {
            out.push(c);
        }
    }
    out
}

fn find(haystack: &[u8], needle: &[u8], from: usize) -> Option<usize> {
    if needle.is_empty() || from > haystack.len() {
        return None;
    }
    haystack[from..].windows(needle.len()).position(|w| w == needle).map(|i| i + from)
}

/// The fields of a `multipart/form-data` body, as `formData()` reads them:
/// a file part's value is `[object File]`. `None` for a body that does not
/// parse, as `formData()` throws on one.
fn multipart_fields(content_type: &str, data: &[u8]) -> Option<Vec<(String, String)>> {
    let boundary = media_param(content_type, "boundary").filter(|b| !b.is_empty())?;
    let delimiter = format!("--{boundary}").into_bytes();
    let mut at = if data.starts_with(&delimiter) {
        0
    } else {
        let crlf = find(data, &[b"\r\n".as_slice(), &delimiter].concat(), 0).map(|i| i + 2);
        let lf = find(data, &[b"\n".as_slice(), &delimiter].concat(), 0).map(|i| i + 1);
        crlf.or(lf)?
    };
    let mut fields = Vec::new();
    loop {
        at += delimiter.len();
        if data[at..].starts_with(b"--") {
            return Some(fields);
        }
        // The rest of the delimiter's line.
        let eol = find(data, b"\n", at)?;
        at = eol + 1;
        // The part's headers, up to an empty line.
        let mut disposition = String::new();
        loop {
            let eol = find(data, b"\n", at)?;
            let line = &data[at..eol];
            let line = line.strip_suffix(b"\r").unwrap_or(line);
            at = eol + 1;
            if line.is_empty() {
                break;
            }
            let line = String::from_utf8_lossy(line);
            if let Some((k, v)) = line.split_once(':') {
                if k.trim().eq_ignore_ascii_case("content-disposition") {
                    disposition = v.trim().to_string();
                }
            }
        }
        // The part's body, up to the next delimiter on a line of its own.
        let next = find(data, &[b"\n".as_slice(), &delimiter].concat(), at)?;
        let mut end = next;
        if end > at && data[end - 1] == b'\r' {
            end -= 1;
        }
        let value = &data[at..end.max(at)];
        at = next + 1;
        let kind = disposition.split(';').next().unwrap_or("").trim();
        let Some(name) = media_param(&disposition, "name").filter(|_| kind.eq_ignore_ascii_case("form-data")) else {
            continue;
        };
        if name.is_empty() {
            continue;
        }
        if media_param(&disposition, "filename").is_some_and(|f| !f.is_empty()) {
            fields.push((name, "[object File]".to_string()));
        } else {
            fields.push((name, String::from_utf8_lossy(value).into_owned()));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn paths_are_read_as_the_url_parser_leaves_them() {
        for (raw, want) in [
            ("/cronwatch/./jobs/x", "/cronwatch/jobs/x"),
            ("/cronwatch/nope/../jobs/x", "/cronwatch/jobs/x"),
            ("/cronwatch\\jobs\\x", "/cronwatch/jobs/x"),
            ("/cronwatch/%2e/jobs/x", "/cronwatch/jobs/x"),
            ("/a/..", "/"),
            ("/a/b/.", "/a/b/"),
            ("/a b/{c}", "/a%20b/%7Bc%7D"),
            ("/é", "/%C3%A9"),
        ] {
            assert_eq!(normalize_path(raw), want, "{raw}");
        }
    }

    #[test]
    fn targets() {
        assert_eq!(request_target("/a?b=c#d"), ("/a".into(), "b=c".into()));
        assert_eq!(request_target("http://host:1/x?y"), ("/x".into(), "y".into()));
        assert_eq!(request_target("http://host"), ("/".into(), String::new()));
        assert_eq!(request_target("*"), ("/".into(), String::new()));
    }

    #[test]
    fn forms_and_json() {
        assert_eq!(
            parse_form(b"a=b+c&&d=%zz&e=%E9"),
            vec![("a".into(), "b c".into()), ("d".into(), "%zz".into()), ("e".into(), "\u{fffd}".into())]
        );
        assert_eq!(form_encode("b c/é"), "b+c%2F%C3%A9");
        assert_eq!(body_field("application/json", br#"{"for":7200000}"#, "for").as_deref(), Some("7200000"));
        assert_eq!(body_field("application/json", "\u{feff}{\"for\":true}".as_bytes(), "for").as_deref(), Some("true"));
        assert_eq!(body_field("application/json", b"{", "for"), None);
        assert_eq!(body_field("application/x-www-form-urlencoded", b"for=1h&for=2h", "for").as_deref(), Some("2h"));
        assert_eq!(body_field("text/plain", b"for=1h", "for"), None);
        let multipart = b"--b\r\nContent-Disposition: form-data; name=\"for\"\r\n\r\n2h\r\n--b--\r\n";
        assert_eq!(body_field("multipart/form-data; boundary=b", multipart, "for").as_deref(), Some("2h"));
        let file = b"--b\r\nContent-Disposition: form-data; name=\"for\"; filename=\"x.txt\"\r\n\r\n2h\r\n--b--\r\n";
        assert_eq!(body_field("multipart/form-data; boundary=\"b\"", file, "for").as_deref(), Some("[object File]"));
        assert_eq!(
            body_field(
                "multipart/form-data; boundary=b",
                b"--b\r\nContent-Disposition: form-data; name=\"for\"\r\n\r\n2h",
                "for"
            ),
            None
        );
        assert_eq!(body_field("multipart/form-data", multipart, "for"), None);
    }

    #[test]
    fn decoding() {
        assert_eq!(safe_decode("a%2Fb").as_deref(), Some("a/b"));
        assert_eq!(safe_decode("%zz"), None);
        assert_eq!(safe_decode("%E9"), None);
        assert_eq!(safe_decode("%"), None);
    }
}
