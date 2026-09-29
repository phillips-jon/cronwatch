//! The SDK's `duration.ts`: durations ("15m", "1h30m", a number of
//! milliseconds) parsed and written as the SDK does.

use crate::js::{Value, format_number, is_space, trim};

fn unit_ms(unit: &str) -> f64 {
    match unit {
        "ms" => 1.0,
        "s" => 1000.0,
        "m" => 60_000.0,
        "h" => 3_600_000.0,
        "d" => 86_400_000.0,
        _ => 604_800_000.0,
    }
}

/// `Math.round`: halves go up, toward positive infinity.
pub(crate) fn round(x: f64) -> f64 {
    let r = x.floor();
    if x - r >= 0.5 { r + 1.0 } else { r }
}

/// The SDK's `parseDuration`: "15m" is 900000. It takes a string or a number
/// of milliseconds, as a stored definition holds either. Compound strings
/// such as "1h30m" are summed, with whitespace allowed between the parts.
/// `label` names the value in the error ("grace", "timeout"); "" is
/// "duration". The errors are the SDK's, word for word.
pub(crate) fn parse_duration(value: &Value, label: &str) -> Result<f64, String> {
    let label = if label.is_empty() { "duration" } else { label };
    match value {
        Value::String(text) => parse_text(text, label),
        Value::Number(n) => parse_number(*n, label),
        other => Err(not_a_duration(label, &js_string(other))),
    }
}

/// `parse_duration` of a number of milliseconds.
pub(crate) fn parse_number(n: f64, label: &str) -> Result<f64, String> {
    let label = if label.is_empty() { "duration" } else { label };
    if !n.is_finite() || n < 0.0 {
        return Err(format!("{label} must be a non-negative number of milliseconds"));
    }
    Ok(n)
}

/// `parse_duration` of text.
pub(crate) fn parse_duration_text(text: &str, label: &str) -> Result<f64, String> {
    parse_text(text, if label.is_empty() { "duration" } else { label })
}

/// `String(value)` for a JSON value, as the SDK's message would quote it.
fn js_string(v: &Value) -> String {
    match v {
        Value::Null => "null".into(),
        Value::Bool(b) => b.to_string(),
        Value::Number(n) => format_number(*n),
        Value::String(s) => s.clone(),
        Value::Array(items) => {
            items.iter().map(|e| if e.is_null() { String::new() } else { js_string(e) }).collect::<Vec<_>>().join(",")
        }
        Value::Object(_) => "[object Object]".into(),
    }
}

fn not_a_duration(label: &str, value: &str) -> String {
    format!("{label} \"{value}\" is not a duration like \"15m\", \"1h30m\" or \"90s\"")
}

/// Reads a duration string as `duration.ts` does: the text trimmed and
/// lowercased, every `/(\d+(?:\.\d+)?)\s*(ms|s|m|h|d|w)/g` match summed, and
/// the whole refused unless the matches, spaces aside, are all of it.
fn parse_text(value: &str, label: &str) -> Result<f64, String> {
    let text = trim(value).to_lowercase();
    if text.is_empty() {
        return Err(format!("{label} is empty"));
    }
    let mut total = 0.0;
    let mut consumed = String::new();
    let mut i = 0;
    while i < text.len() {
        match match_at(&text, i) {
            Some((n, end)) => {
                total += n;
                consumed.push_str(&text[i..end]);
                i = end;
            }
            // The global regular expression moves on one character.
            None => i += text[i..].chars().next().map_or(1, char::len_utf8),
        }
    }
    if strip_spaces(&consumed) != strip_spaces(&text) {
        return Err(not_a_duration(label, value));
    }
    Ok(round(total))
}

/// Tries `(\d+(?:\.\d+)?)\s*(ms|s|m|h|d|w)` at `i`: the value in
/// milliseconds and where the match ends.
fn match_at(text: &str, i: usize) -> Option<(f64, usize)> {
    let b = text.as_bytes();
    let mut j = i;
    while j < b.len() && b[j].is_ascii_digit() {
        j += 1;
    }
    if j == i {
        return None;
    }
    let mut end = j;
    if j + 1 < b.len() && b[j] == b'.' && b[j + 1].is_ascii_digit() {
        end = j + 1;
        while end < b.len() && b[end].is_ascii_digit() {
            end += 1;
        }
    }
    let number = &text[i..end];
    let mut k = end;
    for c in text[end..].chars() {
        if !is_space(c) {
            break;
        }
        k += c.len_utf8();
    }
    let unit = if text[k..].starts_with("ms") {
        "ms"
    } else if k < b.len() && b"smhdw".contains(&b[k]) {
        &text[k..k + 1]
    } else {
        return None;
    };
    let n: f64 = number.parse().ok()?;
    Some((n * unit_ms(unit), k + unit.len()))
}

fn strip_spaces(s: &str) -> String {
    s.chars().filter(|&c| !is_space(c)).collect()
}

/// The SDK's `formatDuration`: 90000 is "1m 30s", at most two units, for
/// messages rather than parsing back. "?" when not finite.
pub(crate) fn format_duration(ms: f64) -> String {
    if !ms.is_finite() {
        return "?".into();
    }
    if ms < 1000.0 {
        return format!("{}ms", format_number(round(ms)));
    }
    let mut parts = Vec::new();
    let mut rest = round(ms / 1000.0);
    for (unit, size) in [("d", 86_400.0), ("h", 3_600.0), ("m", 60.0), ("s", 1.0)] {
        if rest >= size {
            let n = (rest / size).floor();
            rest -= n * size;
            parts.push(format!("{}{unit}", format_number(n)));
        }
        if parts.len() == 2 {
            break;
        }
    }
    if parts.is_empty() { "0s".into() } else { parts.join(" ") }
}

/// The SDK's `formatRelative`: "5m ago", "in 2h", or "now" within five
/// seconds of now.
pub(crate) fn format_relative(at: i64, now: i64) -> String {
    let diff = at.saturating_sub(now);
    let abs = diff.saturating_abs();
    if abs < 5_000 {
        return "now".into();
    }
    let text = format_duration(abs as f64);
    if diff < 0 { format!("{text} ago") } else { format!("in {text}") }
}
