//! What the scheduler integrations share (`cronwatch-tokio-cron-scheduler`
//! and `cronwatch-apalis`), carried over from the Go port's
//! `cronwatch.dev/go/bridge`. An app does not need it; a scheduler
//! integration of your own can.
//!
//! - [`Watch`] declares a scheduler's entries as jobs, one per name, tagged
//!   with the integration and the app, and declares a job whose entry is
//!   gone again without its schedule, so it is never reported missed.
//! - [`check_fires`] checks a schedule taken from a scheduler against the
//!   scheduler's own fire times.
//! - [`Schedule`] is a schedule as CronWatch reads it, with its fire times,
//!   for a scheduler that can be given one (apalis-cron).
//!
//! Which jobs are this app's is told by two tags, the integration's
//! (`tokio-cron-scheduler`) and the app's under it
//! (`tokio-cron-scheduler:<app>`, see [`app_tag`]), so two apps sharing one
//! store never declare each other's jobs without a schedule. That is the
//! PHP port's rule for Laravel and Symfony, as the Go port has it.

mod check;
mod options;
mod watch;

#[cfg(test)]
mod tests;

use std::sync::Arc;
use std::time::Duration;

use md5::{Digest, Md5};

use crate::error::Error;
use crate::schedule::{self, Parsed};

pub use check::{SAMPLE_RUNS, ScheduleError, check_fires, never_fires};
pub use options::{options_of, unscheduled};
pub use watch::{Entry, Watch};

/// The app's name for its tag: `$CRONWATCH_APP_ID` when set, else the name
/// of the running executable. Two apps that share a store and run
/// executables of the same name need `CRONWATCH_APP_ID` (or the
/// integration's `app` option) to tell them apart; every process of one app
/// needs the same.
pub fn app_name() -> String {
    if let Ok(id) = std::env::var("CRONWATCH_APP_ID") {
        let id = id.trim();
        if !id.is_empty() {
            return id.to_string();
        }
    }
    let stem = |path: &std::path::Path| {
        let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        name.strip_suffix(".exe").map(str::to_string).unwrap_or(name)
    };
    if let Ok(exe) = std::env::current_exe() {
        let name = stem(&exe);
        if !name.is_empty() {
            return name;
        }
    }
    std::env::args_os().next().map(|a| stem(std::path::Path::new(&a))).unwrap_or_default()
}

/// The tag that names the app under an integration's tag: `<tag>:<app>`,
/// the app's name lowercased, with anything but letters, digits, `.`, `_`
/// and `-` made `-`. A name that is empty once cleaned, or longer than 48
/// characters, is cut and given 8 hex characters of its MD5, so two names
/// never share a tag. The PHP port's `appTag()`, character for character.
pub fn app_tag(tag: &str, app: &str) -> String {
    // PHP's trim() set, and ASCII letters only, as PHP 8's strtolower (so the
    // Kelvin sign is not a "k").
    let trimmed = app.trim_matches([' ', '\t', '\n', '\r', '\0', '\x0B']);
    let mut slug = String::new();
    let mut run = false;
    for c in trimmed.chars().map(|c| c.to_ascii_lowercase()) {
        if c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, '.' | '_' | '-') {
            slug.push(c);
            run = false;
        } else if !run {
            slug.push('-');
            run = true;
        }
    }
    let mut slug = slug.trim_matches('-').to_string();
    if slug.is_empty() || slug.len() > 48 {
        let sum = Md5::digest(app.as_bytes());
        slug.truncate(39);
        slug = format!("{slug}-").trim_start_matches('-').to_string();
        for b in sum.iter().take(4) {
            slug.push_str(&format!("{b:02x}"));
        }
    }
    format!("{tag}:{slug}")
}

/// Whether `name` is a CronWatch job name: 1 to 120 letters, digits, `.`,
/// `_`, `:` or `-`, starting with a letter or digit.
pub fn valid_name(name: &str) -> bool {
    crate::options::valid_name(name)
}

/// An interval as CronWatch's schedule text, exact to the millisecond:
/// `every 1h30m`.
pub fn every_text(d: Duration) -> String {
    let mut ms = (d.as_nanos() + 500_000) / 1_000_000;
    let mut out = String::new();
    for (name, size) in [("d", 86_400_000u128), ("h", 3_600_000), ("m", 60_000), ("s", 1000), ("ms", 1)] {
        if ms >= size {
            out.push_str(&format!("{}{name}", ms / size));
            ms %= size;
        }
    }
    if out.is_empty() {
        return "every 0ms".into();
    }
    format!("every {out}")
}

/// A schedule as CronWatch reads it (a cron in a zone, or `every
/// <duration>`), with its fire times: what a scheduler that takes a
/// schedule of any kind (apalis-cron) is given, so it runs exactly when
/// CronWatch expects.
#[derive(Clone, Debug)]
pub struct Schedule {
    parsed: Arc<Parsed>,
    text: String,
    zone: String,
}

impl Schedule {
    /// Reads `expr` in `zone` (an IANA name, or `""` for the process's own
    /// zone) with the SDK's rules and messages.
    pub fn parse(expr: &str, zone: &str) -> Result<Schedule, Error> {
        if !zone.is_empty() && !schedule::is_timezone(zone) {
            return Err(Error::Invalid(format!("timezone {} is not an IANA timezone", crate::js::quote(zone))));
        }
        let parsed = schedule::parse(expr, zone).map_err(Error::Invalid)?;
        Ok(Schedule { parsed, text: expr.to_string(), zone: zone.to_string() })
    }

    /// The expression as given.
    pub fn text(&self) -> &str {
        &self.text
    }

    /// The zone as given, `""` for the process's own.
    pub fn zone(&self) -> &str {
        &self.zone
    }

    /// The interval of `every <duration>`, or `None` for a cron.
    pub fn every(&self) -> Option<Duration> {
        self.parsed.is_interval().then(|| Duration::from_millis(self.parsed.every_ms as u64))
    }

    /// The first time a cron fires strictly after `ms` (epoch
    /// milliseconds), or `None` when it never fires again; for an interval,
    /// `ms` plus the interval.
    pub fn fire_after(&self, ms: i64) -> Option<i64> {
        schedule::next_fire(&self.parsed, ms, None)
    }
}
