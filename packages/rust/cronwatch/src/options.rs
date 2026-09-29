//! Job options. The builder is also what keeps a definition's fields in the
//! order they were given: the stored definition is the SDK's JSON, and the
//! SDK writes a job's options in the order its object literal had them, so a
//! Rust process and a Node process declaring the same job write the same
//! bytes.

use std::sync::Arc;
use std::time::Duration;

use crate::error::Error;
use crate::evaluate::{grace_ms, slow_threshold, timeout_ms};
use crate::format::js_text;
use crate::js::{self, Object, Value};
use crate::schedule;
use crate::serialize::{ExpectRule, Matcher};
use crate::types::Definition;

/// What a duration option takes: text like `"15m"`, `"1h30m"`, `"90s"` or
/// `"2d"` (the SDK's form, kept as written in the stored definition), a
/// [`Duration`], or a whole or fractional number of milliseconds. A
/// `Duration` is stored as its milliseconds, as the SDK stores a number.
#[derive(Clone, Debug, PartialEq)]
#[non_exhaustive]
pub enum DurationSpec {
    /// The SDK's text, stored as written.
    Text(String),
    /// Milliseconds.
    Millis(f64),
}

impl DurationSpec {
    pub(crate) fn to_value(&self) -> Value {
        match self {
            DurationSpec::Text(t) => Value::String(t.clone()),
            DurationSpec::Millis(ms) => Value::Number(*ms),
        }
    }
}

impl From<&str> for DurationSpec {
    fn from(text: &str) -> Self {
        DurationSpec::Text(text.to_string())
    }
}
impl From<String> for DurationSpec {
    fn from(text: String) -> Self {
        DurationSpec::Text(text)
    }
}
impl From<&String> for DurationSpec {
    fn from(text: &String) -> Self {
        DurationSpec::Text(text.clone())
    }
}
impl From<Duration> for DurationSpec {
    fn from(d: Duration) -> Self {
        DurationSpec::Millis(d.as_nanos() as f64 / 1e6)
    }
}
impl From<f64> for DurationSpec {
    fn from(ms: f64) -> Self {
        DurationSpec::Millis(ms)
    }
}
impl From<u64> for DurationSpec {
    fn from(ms: u64) -> Self {
        DurationSpec::Millis(ms as f64)
    }
}
impl From<i64> for DurationSpec {
    fn from(ms: i64) -> Self {
        DurationSpec::Millis(ms as f64)
    }
}
impl From<u32> for DurationSpec {
    fn from(ms: u32) -> Self {
        DurationSpec::Millis(ms as f64)
    }
}
impl From<i32> for DurationSpec {
    fn from(ms: i32) -> Self {
        DurationSpec::Millis(ms as f64)
    }
}

/// A job's options: when it runs and what counts as trouble. Each setter
/// appends its field in the order called (a setter called twice keeps its
/// first place and its last value, as a JavaScript object does), so the
/// stored definition is the one a Node process writes for an object literal
/// in that order.
///
/// ```
/// use cronwatch::JobOptions;
/// let options = JobOptions::new().schedule("0 2 * * *").timezone("UTC").grace("15m").expect("Report written");
/// ```
#[derive(Clone, Debug, Default)]
pub struct JobOptions {
    pub(crate) fields: Object,
    pub(crate) expect: Option<ExpectRule>,
}

impl JobOptions {
    /// No options.
    pub fn new() -> Self {
        Self::default()
    }

    fn put(mut self, key: &'static str, value: impl Into<Value>) -> Self {
        self.fields.set(key, value);
        self
    }

    /// When the job is supposed to run: a five or six field cron expression
    /// (`"0 2 * * *"`), a nickname (`"@hourly"`), or an interval
    /// (`"every 5m"`). Leave it out for a job with no fixed cadence:
    /// failures, duration and budgets are still watched, but nothing is ever
    /// missed.
    pub fn schedule(self, expr: impl Into<String>) -> Self {
        self.put("schedule", expr.into())
    }

    /// The IANA zone the cron expression is read in. The default is the
    /// process's zone (`TZ`, else `/etc/localtime`). Vercel and GitHub
    /// Actions run their crons in UTC.
    pub fn timezone(self, name: impl Into<String>) -> Self {
        self.put("timezone", name.into())
    }

    /// How late a run may start before it counts as missed. Default 10m.
    pub fn grace(self, d: impl Into<DurationSpec>) -> Self {
        let v = d.into().to_value();
        self.put("grace", v)
    }

    /// How long a run may go on before it is treated as stuck and marked
    /// timeout. Default 1h. [`JobContext::cancelled`](crate::JobContext::cancelled)
    /// resolves when it passes.
    pub fn timeout(self, d: impl Into<DurationSpec>) -> Self {
        let v = d.into().to_value();
        self.put("timeout", v)
    }

    /// Alerts when a successful run takes longer. Without it, a run is slow
    /// when it takes more than twice the p95 of recent runs (and over 10s),
    /// once there are five runs to compare against.
    pub fn max_duration(self, d: impl Into<DurationSpec>) -> Self {
        let v = d.into().to_value();
        self.put("maxDuration", v)
    }

    /// A ceiling for a metric reported with `JobContext::metric`:
    /// `budget("cost", 2.0)` alerts when a run reports cost above 2. Give it
    /// once per metric. Metrics without a ceiling alert when a run reports
    /// more than three times the recent median, once there are five runs to
    /// compare against.
    pub fn budget(mut self, metric: impl Into<String>, ceiling: f64) -> Self {
        let mut budget = self.fields.get("budget").and_then(Value::as_object).cloned().unwrap_or_default();
        budget.set(metric.into(), ceiling);
        self.fields.set("budget", budget);
        self
    }

    /// Makes a successful run fail unless its output contains `text`.
    /// Catches the job that exits cleanly and did nothing.
    pub fn expect(mut self, text: impl Into<String>) -> Self {
        self.expect = Some(ExpectRule::Contains(text.into()));
        self
    }

    /// Makes a successful run fail unless the pattern matches its output.
    pub fn expect_match(mut self, matcher: impl Matcher + 'static) -> Self {
        self.expect = Some(ExpectRule::Matches(Arc::new(matcher)));
        self
    }

    /// Makes a successful run fail unless `check` returns true for its
    /// output. A panic in `check` fails the run with what it panicked with.
    pub fn expect_fn(mut self, check: impl Fn(&str) -> bool + Send + Sync + 'static) -> Self {
        self.expect = Some(ExpectRule::Func(Arc::new(check)));
        self
    }

    /// Alerts on the nth consecutive failure rather than the first. Default 1.
    pub fn failures_before_alert(self, n: u32) -> Self {
        self.put("failuresBeforeAlert", n)
    }

    /// Describes the job on the dashboard.
    pub fn description(self, text: impl Into<String>) -> Self {
        self.put("description", text.into())
    }

    /// Labels for the job.
    pub fn tags<I, S>(self, tags: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        let list: Vec<Value> = tags.into_iter().map(|t| Value::String(t.into())).collect();
        self.put("tags", list)
    }

    /// Sets any field of the stored definition as JSON, for a field this
    /// release has no setter for.
    pub fn field(mut self, key: impl Into<String>, value: impl Into<Value>) -> Self {
        self.fields.set(key.into(), value);
        self
    }

    /// These options followed by `other`'s, as JavaScript spreads two option
    /// objects into one (`{ ...these, ...other }`): a field both set keeps
    /// its place here and takes `other`'s value, and `other`'s expect rule,
    /// when it has one, replaces this one's. A source uses it to put an
    /// app's options between its own.
    pub fn merge(mut self, other: JobOptions) -> Self {
        for (k, v) in other.fields.iter() {
            self.fields.set(k, v.clone());
        }
        if other.expect.is_some() {
            self.expect = other.expect;
        }
        self
    }
}

/// Whether a job name is 1 to 120 characters of letters, digits, `.`, `_`,
/// `:` or `-`, starting with a letter or digit.
pub(crate) fn valid_name(name: &str) -> bool {
    let b = name.as_bytes();
    !b.is_empty()
        && b.len() <= 120
        && b[0].is_ascii_alphanumeric()
        && b.iter().all(|&c| c.is_ascii_alphanumeric() || matches!(c, b'.' | b'_' | b':' | b'-'))
}

/// The SDK's error for options that would otherwise quietly turn a check off.
pub(crate) fn validate_definition(name: &str, def: &Definition) -> Result<(), Error> {
    let invalid = |m: String| Err(Error::Invalid(m));
    let quoted = js::quote(name);
    if let Some(v) = def.get("schedule") {
        let text = v.as_str().filter(|s| !js::trim(s).is_empty());
        let Some(text) = text else {
            return invalid(format!("job {quoted}: schedule must be a non-empty string"));
        };
        // Croner takes any zone when it reads an expression and fails on a bad
        // one only when asked for a fire time, so the SDK reports a bad zone
        // after the expression, with a message of its own (below). This port's
        // parser checks the zone at once, so a zone that is not one is left
        // out here.
        let tz = def.get("timezone").and_then(Value::as_str).filter(|tz| schedule::is_timezone(tz)).unwrap_or("");
        schedule::parse(text, tz).map_err(Error::Invalid)?;
    }
    if let Some(v) = def.get("timezone") {
        let tz = v.as_str().unwrap_or("");
        if !schedule::is_timezone(tz) {
            return invalid(format!("job {quoted}: timezone {} is not an IANA timezone", js::quote(tz)));
        }
    }
    if def.get("grace").is_some() {
        grace_ms(def).map_err(Error::Invalid)?;
    }
    if def.get("timeout").is_some() && timeout_ms(def).map_err(Error::Invalid)? <= 0.0 {
        return invalid(format!("job {quoted}: timeout must be longer than zero"));
    }
    if def.get("maxDuration").is_some() {
        let ms = slow_threshold(def, &[]).map_err(Error::Invalid)?.map_or(0.0, |t| t.0);
        if ms <= 0.0 {
            return invalid(format!("job {quoted}: maxDuration must be longer than zero"));
        }
    }
    if let Some(v) = def.get("failuresBeforeAlert") {
        let n = v.as_f64().unwrap_or(0.0);
        if !js::is_integer(n) || n < 1.0 {
            return invalid(format!(
                "job {quoted}: failuresBeforeAlert must be a whole number, 1 or more (got {})",
                js_text(Some(v))
            ));
        }
    }
    if let Some(Value::Object(budget)) = def.get("budget") {
        for (metric, v) in budget.iter() {
            let ceiling = v.as_f64().unwrap_or(0.0);
            if !ceiling.is_finite() || ceiling < 0.0 {
                return invalid(format!(
                    "job {quoted}: budget.{metric} must be a finite number, 0 or more (got {})",
                    js::format_number(ceiling)
                ));
            }
        }
    }
    Ok(())
}

/// Where alerts are sent from.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
#[non_exhaustive]
pub enum Deliver {
    /// Each alert goes out from the process that produced it. The default.
    #[default]
    Now,
    /// Nothing is sent from this process: each alert is queued in the store,
    /// and the next check in a process that delivers now sends it (with
    /// triage). For a process that records runs but cannot reach the
    /// network, such as a sandboxed backup job.
    AtCheck,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_follow_the_sdks_rule() {
        assert!(valid_name("nightly-report"));
        assert!(valid_name("a.b_c:d-1"));
        assert!(!valid_name(""));
        assert!(!valid_name("-x"));
        assert!(!valid_name("a b"));
        assert!(!valid_name(&"a".repeat(121)));
        assert!(valid_name(&"a".repeat(120)));
    }

    #[test]
    fn fields_keep_the_order_given() {
        let o =
            JobOptions::new().grace("5m").schedule("@hourly").budget("cost", 2.0).budget("rows", 5.0).grace(900_000u64);
        assert_eq!(o.fields.to_json(), r#"{"grace":900000,"schedule":"@hourly","budget":{"cost":2,"rows":5}}"#);
        let d = JobOptions::new().timeout(Duration::from_millis(1500));
        assert_eq!(d.fields.to_json(), r#"{"timeout":1500}"#);
    }

    #[test]
    fn merged_options_spread_as_javascript_does() {
        let a = JobOptions::new().description("a").tags(["x"]).expect("one");
        let b = JobOptions::new().grace("1m").description("b").expect("two");
        let m = a.merge(b).schedule("@hourly");
        assert_eq!(m.fields.to_json(), r#"{"description":"b","tags":["x"],"grace":"1m","schedule":"@hourly"}"#);
        assert!(matches!(m.expect, Some(ExpectRule::Contains(ref t)) if t == "two"));
    }
}
