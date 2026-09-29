//! Job options from a stored definition: the ones that declare it again as
//! it is (`options_of`, for a worker whose job another process scheduled),
//! and the ones that declare it again without its schedule (`unscheduled`).

use crate::js::{self, Value};
use crate::jsre::Regexp;
use crate::options::{DurationSpec, JobOptions};
use crate::serialize::Matcher;
use crate::types::Definition;

/// The options a job keeps when it is declared again without its schedule,
/// as the PHP and Go ports keep them.
const KEPT: [&str; 6] = ["tags", "grace", "timeout", "maxDuration", "budget", "failuresBeforeAlert"];

/// The options that declare a job again without its schedule: its
/// description followed by ` (no longer scheduled)` (`A scheduled task`
/// when it had none), its tags, grace, timeout, maxDuration, budget and
/// failuresBeforeAlert.
pub fn unscheduled(def: &Definition) -> JobOptions {
    let mut description = def.description().to_string();
    if description.is_empty() {
        description = "A scheduled task".into();
    }
    if !description.ends_with(" (no longer scheduled)") {
        description.push_str(" (no longer scheduled)");
    }
    let mut options = JobOptions::new().description(description);
    for key in KEPT {
        if def.get(key).is_some() {
            options = with_field(options, def, key);
        }
    }
    options
}

/// The options that declare a stored definition again, in its order:
/// schedule, timezone, grace, timeout, maxDuration, budget,
/// failuresBeforeAlert, description, tags, and expect (`contains` as
/// `expect`, a pattern as a matcher of the same source, run by the
/// JavaScript regular expression engine the redaction uses, and a custom
/// function as one that passes every output, since the function is the
/// other process's). Fields no option gives are left out.
pub fn options_of(def: &Definition) -> JobOptions {
    let mut options = JobOptions::new();
    for key in def.keys() {
        options = match key {
            "schedule" | "timezone" | "description" => match def.get(key).and_then(Value::as_str) {
                Some(text) => match key {
                    "schedule" => options.schedule(text),
                    "timezone" => options.timezone(text),
                    _ => options.description(text),
                },
                None => options,
            },
            "expect" => expect_of(options, def.expect()),
            other => with_field(options, def, other),
        };
    }
    options
}

/// `options` with one of the fields `unscheduled` keeps, as stored: a
/// duration's text as text and a number of milliseconds as a number, a
/// budget in the order its metrics were given.
fn with_field(options: JobOptions, def: &Definition, key: &str) -> JobOptions {
    let value = def.get(key);
    let duration = |v: Option<&Value>| match v {
        Some(Value::String(text)) => Some(DurationSpec::Text(text.clone())),
        Some(Value::Number(ms)) => Some(DurationSpec::Millis(*ms)),
        _ => None,
    };
    match key {
        "tags" => options.tags(def.tags()),
        "grace" => match duration(value) {
            Some(d) => options.grace(d),
            None => options,
        },
        "timeout" => match duration(value) {
            Some(d) => options.timeout(d),
            None => options,
        },
        "maxDuration" => match duration(value) {
            Some(d) => options.max_duration(d),
            None => options,
        },
        "budget" => match value {
            Some(Value::Object(budget)) => budget
                .iter()
                .filter_map(|(metric, v)| v.as_f64().map(|ceiling| (metric, ceiling)))
                .fold(options, |o, (metric, ceiling)| o.budget(metric, ceiling)),
            _ => options,
        },
        "failuresBeforeAlert" => match value.and_then(Value::as_f64) {
            Some(n) if n >= 0.0 && n <= f64::from(u32::MAX) && n.fract() == 0.0 => {
                options.failures_before_alert(n as u32)
            }
            _ => options,
        },
        _ => options,
    }
}

/// `options` with the expect rule a stored description came from.
fn expect_of(options: JobOptions, text: &str) -> JobOptions {
    if let Some(rest) = text.strip_prefix("contains ") {
        if let Ok(Value::String(want)) = js::parse(rest) {
            return options.expect(want);
        }
    } else if let Some(source) = text.strip_prefix("matches ") {
        return options.expect_match(StoredPattern::new(source));
    } else if text == "custom function" {
        return options.expect_fn(|_| true);
    }
    options
}

/// A pattern as another process stored it, `/source/flags`: matched with
/// the JavaScript engine when it can read it, and passing every output when
/// it cannot, so the definition written back is the one stored.
struct StoredPattern {
    source: String,
    regexp: Option<Regexp>,
}

impl StoredPattern {
    fn new(source: &str) -> StoredPattern {
        let regexp = source
            .strip_prefix('/')
            .and_then(|rest| rest.rfind('/').map(|end| (&rest[..end], &rest[end + 1..])))
            .and_then(|(body, flags)| Regexp::new(body, flags).ok());
        StoredPattern { source: source.to_string(), regexp }
    }
}

impl Matcher for StoredPattern {
    fn is_match(&self, text: &str) -> bool {
        self.regexp.as_ref().is_none_or(|r| r.is_match(text))
    }

    fn source(&self) -> String {
        self.source.clone()
    }
}
