//! Alert titles and messages (format.ts), character for character, and the
//! numbers in them as JavaScript's `toLocaleString("en-US")` writes them.

use crate::evaluate::{AlertDraft, truthy};
use crate::js::{self, Value};
use crate::schedule::format_duration;
use crate::types::{Alert, AlertDetails, AlertType, Definition};

/// format.ts `andList`: words joined as an English list, with a serial
/// comma from three on: `a`, `a and b`, `a, b, and c`.
pub(crate) fn and_list<S: AsRef<str>>(words: &[S]) -> String {
    match words {
        [] => String::new(),
        [one] => one.as_ref().to_string(),
        [a, b] => format!("{} and {}", a.as_ref(), b.as_ref()),
        [rest @ .., last] => {
            let head: Vec<&str> = rest.iter().map(AsRef::as_ref).collect();
            format!("{}, and {}", head.join(", "), last.as_ref())
        }
    }
}

/// evaluate.ts `formatNumber`: a whole number grouped in thousands
/// (`1,234`), anything else rounded to at most four decimals (`0.0123`), as
/// `Intl.NumberFormat("en-US")` writes them. ICU starts from the shortest
/// decimal digits that read back as the number (as `String(n)` has them, so
/// 1234.56785 is those digits, not the binary value just below), rounds half
/// away from zero (0.03125 is `0.0313`), and keeps the sign of a negative
/// number that rounds to zero (`-0`).
pub(crate) fn format_number(n: f64) -> String {
    if n.is_nan() {
        return "NaN".into();
    }
    if n.is_infinite() {
        return if n > 0.0 { "∞".into() } else { "-∞".into() };
    }
    let sign = if n.is_sign_negative() { "-" } else { "" };
    // The shortest digits d1...dk, with the value 0.d1...dk * 10^point.
    let text = format!("{:e}", n.abs());
    let (mantissa, exp) = text.split_once('e').unwrap_or((&text, "0"));
    let digits: String = mantissa.chars().filter(|&c| c != '.').collect();
    let mut point = exp.parse::<i64>().unwrap_or(0) + 1;
    if digits == "0" {
        point = 1;
    }
    // Written out in full: whole digits and fraction digits.
    let (mut whole, mut frac) = if point <= 0 {
        ("0".to_string(), "0".repeat((-point) as usize) + &digits)
    } else if point as usize >= digits.len() {
        (digits.clone() + &"0".repeat(point as usize - digits.len()), String::new())
    } else {
        (digits[..point as usize].to_string(), digits[point as usize..].to_string())
    };
    if frac.len() > 4 {
        let mut kept: Vec<u8> = format!("{whole}{}", &frac[..4]).into_bytes();
        if frac.as_bytes()[4] >= b'5' {
            // Add one to the decimal digits, carrying.
            let mut i = kept.len();
            loop {
                if i == 0 {
                    kept.insert(0, b'1');
                    break;
                }
                i -= 1;
                if kept[i] == b'9' {
                    kept[i] = b'0';
                } else {
                    kept[i] += 1;
                    break;
                }
            }
        }
        let mut s = String::from_utf8(kept).unwrap_or_default();
        let trimmed = s.trim_start_matches('0').len();
        s = s[s.len() - trimmed.max(1)..].to_string();
        while s.len() < 5 {
            s.insert(0, '0');
        }
        whole = s[..s.len() - 4].to_string();
        frac = s[s.len() - 4..].to_string();
    }
    let frac = frac.trim_end_matches('0');
    let mut out = format!("{sign}{}", group(&whole));
    if !frac.is_empty() {
        out.push('.');
        out.push_str(frac);
    }
    out
}

/// A comma between each three digits, from the right.
fn group(digits: &str) -> String {
    if digits.len() <= 3 {
        return digits.to_string();
    }
    let mut b = String::new();
    let head = digits.len() % 3;
    if head > 0 {
        b.push_str(&digits[..head]);
    }
    let mut i = head;
    while i < digits.len() {
        if !b.is_empty() {
            b.push(',');
        }
        b.push_str(&digits[i..i + 3]);
        i += 3;
    }
    b
}

/// `2026-01-05 09:30:00 UTC (5m ago)`, or `before 0001-01-01 00:00:00 UTC`
/// (with no relative part) for a time outside the years 1 to 9999.
fn when(at: f64, now: i64) -> String {
    if !js::in_date_range(at) {
        return js::beyond_dates(at).to_string();
    }
    let iso = js::iso_string(at.trunc() as i64).replacen('T', " ", 1);
    format!("{} UTC ({})", &iso[..19.min(iso.len())], relative(at, now))
}

fn when_int(at: i64, now: i64) -> String {
    when(at as f64, now)
}

/// `formatRelative` for a time that may carry a fraction of a millisecond (a
/// deadline with a fractional grace).
fn relative(at: f64, now: i64) -> String {
    let diff = at - now as f64;
    let abs = diff.abs();
    if abs < 5_000.0 {
        return "now".into();
    }
    let text = format_duration(abs);
    if diff < 0.0 { format!("{text} ago") } else { format!("in {text}") }
}

fn first_lines(text: &str, n: usize) -> String {
    text.split('\n').take(n).collect::<Vec<_>>().join("\n")
}

fn tail(text: Option<&str>, n: usize) -> String {
    let Some(text) = text.filter(|t| !t.is_empty()) else {
        return String::new();
    };
    let lines: Vec<&str> = js::trim_end(text).split('\n').collect();
    lines[lines.len().saturating_sub(n)..].join("\n")
}

/// Whether the text starts `Name: `, as `/^[A-Za-z_$][\w$]*: /` matches.
fn names_itself(text: &str) -> bool {
    let b = text.as_bytes();
    if b.is_empty() || !(b[0].is_ascii_alphabetic() || b[0] == b'_' || b[0] == b'$') {
        return false;
    }
    let end = b.iter().position(|&c| !(c.is_ascii_alphanumeric() || c == b'_' || c == b'$')).unwrap_or(b.len());
    b[end..].starts_with(b": ")
}

/// `Error: x` for a bare message, but not `Error: TypeError: x` for one that
/// already names itself.
fn error_line(err: &str) -> String {
    let text = first_lines(err, 4);
    if names_itself(&text) { text } else { format!("Error: {text}") }
}

/// A JSON value as a JavaScript template literal writes it, and `undefined`
/// for a field that is absent.
pub(crate) fn js_text(v: Option<&Value>) -> String {
    let Some(v) = v else {
        return "undefined".into();
    };
    match v {
        Value::Null => "null".into(),
        Value::String(s) => s.clone(),
        Value::Bool(b) => b.to_string(),
        Value::Number(n) => js::format_number(*n),
        Value::Array(list) => list
            .iter()
            .map(|e| if e.is_null() { String::new() } else { js_text(Some(e)) })
            .collect::<Vec<_>>()
            .join(","),
        Value::Object(_) => "[object Object]".into(),
    }
}

/// Turns a draft into the title and message every channel shows.
pub(crate) fn compose_alert(draft: AlertDraft, def: &Definition, now: i64) -> Alert {
    let name = js_text(def.get("name"));
    let run = draft.run.as_ref();
    let mut lines: Vec<String> = Vec::new();
    let title = match (&draft.alert_type, &draft.details) {
        (AlertType::Missed, AlertDetails::Missed { due_at, deadline, grace_ms, .. }) => {
            lines.push(format!(
                "Due {}, and no run had started by {} (grace {}).",
                when(*due_at as f64, now),
                when(*deadline, now),
                format_duration(*grace_ms)
            ));
            let zone = match def.get("timezone") {
                Some(tz) if truthy(tz) => format!(" ({})", js_text(Some(tz))),
                _ => String::new(),
            };
            lines.push(format!("Schedule: {}{zone}.", js_text(def.get("schedule"))));
            let last = run.map_or("never".to_string(), |r| format!("{} {}", r.status, when_int(r.started_at, now)));
            lines.push(format!("Last run: {last}."));
            format!("{name} missed its scheduled run")
        }
        (AlertType::Failed, details) => {
            if let AlertDetails::Failure { consecutive_failures, .. } = details {
                if *consecutive_failures > 1 {
                    lines.push(format!("{} consecutive failures.", js::format_number(*consecutive_failures as f64)));
                }
            }
            if let Some(run) = run {
                let ran = run.duration_ms.map_or(String::new(), |d| format!(", ran {}", format_duration(d as f64)));
                lines.push(format!("Started {}{ran}.", when_int(run.started_at, now)));
                if let Some(err) = run.error.as_deref().filter(|e| !e.is_empty()) {
                    lines.push(error_line(err));
                }
                let out = tail(run.output.as_deref(), 8);
                if !out.is_empty() {
                    lines.push(format!("Output (tail):\n{out}"));
                }
            }
            format!("{name} failed")
        }
        (AlertType::Stuck, _) => {
            if let Some(run) = run {
                let ran = run.duration_ms.map_or(now.saturating_sub(run.started_at) as f64, |d| d as f64);
                lines.push(format!(
                    "Started {} and never reported finishing. Marked as timed out after {}.",
                    when_int(run.started_at, now),
                    format_duration(ran)
                ));
                let out = tail(run.output.as_deref(), 8);
                if !out.is_empty() {
                    lines.push(format!("Output so far (tail):\n{out}"));
                }
            }
            lines.push(
                "If the process was killed mid-run (a serverless timeout, a deploy), this is what that looks like."
                    .into(),
            );
            format!("{name} is stuck")
        }
        (AlertType::Slow, AlertDetails::Slow { duration_ms, threshold_ms, basis }) => {
            lines.push(format!(
                "Took {}; the limit is {} ({basis}).",
                format_duration(*duration_ms as f64),
                format_duration(*threshold_ms)
            ));
            if let Some(run) = run {
                lines.push(format!("Started {}.", when_int(run.started_at, now)));
            }
            format!("{name} was slow")
        }
        (AlertType::OverBudget, AlertDetails::OverBudget { breaches }) => {
            for b in breaches {
                lines.push(format!(
                    "{}: {}, limit {} ({}).",
                    b.metric,
                    format_number(b.value),
                    format_number(b.limit),
                    b.basis
                ));
            }
            if let Some(run) = run {
                lines.push(format!("Started {}.", when_int(run.started_at, now)));
            }
            format!("{name} went over budget")
        }
        (AlertType::UnderFloor, AlertDetails::UnderFloor { breaches }) => {
            for b in breaches {
                lines.push(if b.basis == "floor" {
                    format!("{}: {}, below the floor of {}.", b.metric, format_number(b.value), format_number(b.limit))
                } else {
                    format!("{}: {} ({}).", b.metric, format_number(b.value), b.basis)
                });
            }
            if let Some(run) = run {
                lines.push(format!("Started {}.", when_int(run.started_at, now)));
            }
            format!("{name} fell short")
        }
        (AlertType::Recovered, AlertDetails::Recovered { reason, since, .. })
            if reason.as_deref() == Some("unscheduled") =>
        {
            let missed = since.map_or(String::new(), |s| format!("Missed since {}. ", when_int(s, now)));
            lines.push(format!("{missed}It has no schedule now, so nothing is due; the missed alert is closed."));
            format!("{name} is no longer scheduled")
        }
        (AlertType::Recovered, AlertDetails::Recovered { after, .. }) => {
            let after = and_list(&after.iter().map(|c| c.as_str().replacen('_', " ", 1)).collect::<Vec<_>>());
            let at = run.map_or("just now".to_string(), |r| when_int(r.started_at, now));
            let mut line = format!("A run {at} succeeded");
            if !after.is_empty() {
                line.push_str(&format!(" after: {after}"));
            }
            lines.push(format!("{line}."));
            if let Some(d) = run.and_then(|r| r.duration_ms) {
                lines.push(format!("Ran {}.", format_duration(d as f64)));
            }
            format!("{name} recovered")
        }
        _ => String::new(),
    };
    Alert {
        alert_type: draft.alert_type,
        run: draft.run,
        details: draft.details,
        job: name,
        definition: def.clone(),
        title,
        message: lines.join("\n"),
        triage: None,
        triage_tried: false,
        at: now,
        kept: Default::default(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn numbers_as_to_locale_string_writes_them() {
        let cases: &[(f64, &str)] = &[
            (1234.0, "1,234"),
            (1234567.0, "1,234,567"),
            (0.0123, "0.0123"),
            (0.03125, "0.0313"),
            (1234.56785, "1,234.5679"),
            (-0.00001, "-0"),
            (0.99999, "1"),
            (9999.99995, "10,000"),
            (1.5, "1.5"),
            (1e21, "1,000,000,000,000,000,000,000"),
            (f64::INFINITY, "∞"),
            (0.0, "0"),
        ];
        for &(n, want) in cases {
            assert_eq!(format_number(n), want, "{n}");
        }
    }

    #[test]
    fn errors_name_themselves_once() {
        assert_eq!(error_line("TypeError: x"), "TypeError: x");
        assert_eq!(error_line("boom"), "Error: boom");
        assert_eq!(error_line("a\nb\nc\nd\ne"), "Error: a\nb\nc\nd");
    }
}
