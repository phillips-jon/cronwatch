//! The check that a schedule taken from a scheduler (tokio-cron-scheduler's
//! cron read by the `croner` crate, a `cron` crate schedule apalis-cron
//! runs) makes CronWatch expect runs exactly when the scheduler makes them,
//! as the Go port checks robfig/cron's and the gem Solid Queue's against
//! Fugit: the scheduler's own runs, from its own code, walked beside
//! CronWatch's fires around every clock change in the next few years and
//! from the start of each month of a sample year, so the answer does not
//! depend on when the app starts.
//!
//! Between two runs of the scheduler, CronWatch must not want one of its
//! own, or it would report it missed: a fire CronWatch has and the
//! scheduler does not (a time the scheduler skips when clocks go forward, a
//! run its steps drop that day) is refused unless the run before it covers
//! it (a minute of early slack, or a fire moved past a spring-forward jump).
//! Away from clock changes every run the scheduler makes must also be one
//! CronWatch expects; near one, the scheduler may run a repeated time twice,
//! which CronWatch takes as an early run. The Go port's `bridge/check.go`,
//! line for line.

use std::collections::{HashMap, HashSet};
use std::fmt;

use jiff::Timestamp;
use jiff::tz::TimeZone;

use crate::js::{self, date_utc};
use crate::schedule::cron::{offset, wall_at};
use crate::schedule::{self, Parsed};

/// How far ahead the daylight saving check looks, and how far either side
/// of each clock change it compares the scheduler's runs with CronWatch's.
const HORIZON_YEARS: i64 = 5;
const CHANGE_WINDOW_MS: i64 = 2 * 86_400_000;
/// Away from clock changes, `SAMPLE_RUNS` runs from the start of each month
/// of a fixed year are compared too.
const SAMPLE_YEAR: i64 = 2026;
const DAY_MS: i64 = 86_400_000;

/// How many runs a runs function gives after the first when it is asked
/// without an end.
pub const SAMPLE_RUNS: usize = 8;

/// A scheduler's schedule that cannot be read, or cannot be taken as
/// CronWatch's exactly: the job is watched without a schedule, and the error
/// reported once.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScheduleError {
    message: String,
    never: bool,
}

impl ScheduleError {
    /// A refusal with its message.
    pub fn new(message: impl Into<String>) -> ScheduleError {
        ScheduleError { message: message.into(), never: false }
    }

    /// The message.
    pub fn message(&self) -> &str {
        &self.message
    }
}

impl fmt::Display for ScheduleError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for ScheduleError {}

/// What a runs function answers for a schedule that never fires again.
pub fn never_fires(why: impl Into<String>) -> ScheduleError {
    ScheduleError { message: why.into(), never: true }
}

/// A clock change: when, and the zone's offset in seconds before and after.
#[derive(Clone, Copy)]
struct Transition {
    at: i64,
    before: i64,
    after: i64,
}

/// The zone's clock changes between two instants, in epoch milliseconds.
fn transitions(tz: &TimeZone, start_ms: i64, end_ms: i64) -> Vec<Transition> {
    let Ok(start) = Timestamp::from_millisecond(start_ms) else {
        return Vec::new();
    };
    let mut found = Vec::new();
    let mut before = offset(start_ms.div_euclid(1000), tz);
    for t in tz.following(start) {
        let at = t.timestamp().as_millisecond();
        if at > end_ms {
            break;
        }
        let after = i64::from(t.offset().seconds());
        if after != before {
            found.push(Transition { at, before, after });
        }
        before = after;
    }
    found
}

fn year_start(year: i64) -> i64 {
    date_utc(year, 0, 1, 0, 0, 0, 0)
}

/// Refuses a cron CronWatch would not expect runs of when the scheduler
/// makes them, with an error naming `where_` (the job, for the message) and
/// `scheduler` (its name). `runs` are the scheduler's own runs, from its own
/// code: given `(start, end)` in epoch milliseconds, the one at or before
/// `start` and every one after it up to the first past `end`, or
/// [`SAMPLE_RUNS`] of them after that first one when `end` is `None`,
/// ascending ([`never_fires`] for a schedule that never fires again).
/// `expr` and `zone` are the schedule as CronWatch reads it, `zone` `""` for
/// the process's own. `daily` is a cron that names no day or month, which
/// meets every clock change of one kind alike, so one of each is walked.
/// `now` is the epoch milliseconds the horizon starts from.
pub fn check_fires(
    runs: &dyn Fn(i64, Option<i64>) -> Result<Vec<i64>, ScheduleError>,
    expr: &str,
    zone: &str,
    where_: &str,
    scheduler: &str,
    daily: bool,
    now: i64,
) -> Result<(), ScheduleError> {
    let parsed = schedule::parse(expr, zone).map_err(|e| {
        ScheduleError::new(format!("{where_} is {}, which CronWatch cannot read: {e}", js::quote(expr)))
    })?;
    let tz = schedule::load_zone(zone).map_err(|e| ScheduleError::new(format!("{where_}: {e}")))?;
    let checker =
        Checker { runs, parsed: &parsed, tz, zone, where_: format!("{where_} is {}", js::quote(expr)), scheduler };
    match checker.check(daily, now) {
        Err(e) if e.never => Err(ScheduleError::new(format!("{}, which never fires: {}", checker.where_, e.message))),
        other => other,
    }
}

struct Checker<'a> {
    runs: &'a dyn Fn(i64, Option<i64>) -> Result<Vec<i64>, ScheduleError>,
    parsed: &'a Parsed,
    tz: TimeZone,
    zone: &'a str,
    where_: String,
    scheduler: &'a str,
}

impl Checker<'_> {
    fn check(&self, daily: bool, now: i64) -> Result<(), ScheduleError> {
        let year = wall_at(now.div_euclid(1000), &TimeZone::UTC)[0];
        let mut seen = HashSet::new();
        for change in transitions(&self.tz, year_start(year), year_start(year + HORIZON_YEARS + 1)) {
            let kind = ((change.at / 1000 + change.before).rem_euclid(86_400), change.after - change.before);
            if daily && seen.contains(&kind) {
                continue;
            }
            seen.insert(kind);
            let start = change.at - CHANGE_WINDOW_MS;
            let end = start + 2 * CHANGE_WINDOW_MS;
            // Near a change only CronWatch's own fires can be refused, so a
            // stretch where it has none needs no walk.
            match schedule::fire_after(self.parsed, start - 1) {
                Some(first) if first <= end => {}
                _ => continue,
            }
            let found = (self.runs)(start, Some(end))?;
            self.compare(&found, false)?;
        }

        let mut compared_until: Option<i64> = None;
        for month in 0..12 {
            let start = date_utc(SAMPLE_YEAR, month, 1, 0, 0, 0, 0);
            if compared_until.is_some_and(|until| start < until) {
                continue; // a sparse cron's earlier sample reached past this month
            }
            let found = (self.runs)(start, None)?;
            let Some(&last) = found.last() else {
                continue;
            };
            compared_until = Some(last);
            let near = !transitions(&self.tz, found[0] - DAY_MS, last + DAY_MS).is_empty();
            self.compare(&found, !near)?;
        }
        Ok(())
    }

    /// CronWatch's fires after `start`, up to and including `end`.
    fn fires(&self, start: i64, end: i64) -> Vec<i64> {
        let mut out = Vec::new();
        let mut at = start;
        while let Some(fire) = schedule::fire_after(self.parsed, at) {
            if fire > end {
                break;
            }
            out.push(fire);
            at = fire;
        }
        out
    }

    /// Refuses where, after one of the scheduler's runs, CronWatch would want
    /// a run before the scheduler's next (or, when strict, where the
    /// scheduler's next is not a time CronWatch fires).
    fn compare(&self, runs: &[i64], strict: bool) -> Result<(), ScheduleError> {
        if runs.len() < 2 {
            return Ok(());
        }
        let fires = self.fires(runs[0], runs[runs.len() - 1]);
        let expected: HashMap<i64, ()> = if strict { fires.iter().map(|&f| (f, ())).collect() } else { HashMap::new() };
        let mut i = 0;
        for pair in runs.windows(2) {
            let (at, following) = (pair[0], pair[1]);
            while i < fires.len() && fires[i] <= at {
                i += 1;
            }
            let own = i >= fires.len() || fires[i] < following;
            let unexpected = strict && !expected.contains_key(&following);
            if !own && !unexpected {
                continue;
            }
            let due = schedule::due_after_run(self.parsed, at);
            if !unexpected && due.is_some_and(|d| d >= following) {
                continue;
            }
            return Err(self.mismatch(at, following, due));
        }
        Ok(())
    }

    fn zone_name(&self) -> &str {
        if self.zone.is_empty() { "the process's zone" } else { self.zone }
    }

    fn stamp(&self, ms: i64) -> String {
        let w = wall_at(ms.div_euclid(1000), &self.tz);
        format!("{:04}-{:02}-{:02} {:02}:{:02}:{:02}", w[0], w[1], w[2], w[3], w[4], w[5])
    }

    fn mismatch(&self, at: i64, following: i64, due: Option<i64>) -> ScheduleError {
        let skipped = due.and_then(|due| {
            transitions(&self.tz, due - DAY_MS, due + 1000).into_iter().find(|change| {
                let gap = change.after - change.before;
                gap > 0 && due < change.at + gap * 1000
            })
        });
        let Some(skipped) = skipped else {
            let expected = due.map_or_else(|| "nothing".to_string(), |d| self.stamp(d));
            return ScheduleError::new(format!(
                "{} in {}, but after a run at {} {} runs it next at {} and CronWatch would expect {expected}, so it cannot be converted exactly; give the job a schedule of its own",
                self.where_,
                self.zone_name(),
                self.stamp(at),
                self.scheduler,
                self.stamp(following)
            ));
        };
        let old = wall_at((skipped.at + skipped.before * 1000).div_euclid(1000), &TimeZone::UTC);
        let new = wall_at((skipped.at + skipped.after * 1000).div_euclid(1000), &TimeZone::UTC);
        ScheduleError::new(format!(
            "{}, due at a time that does not exist in {} on {:04}-{:02}-{:02}, when clocks go forward from {:02}:{:02} to {:02}:{:02}. \
             {} does not run it then and CronWatch would expect it at {}, so it would be reported missed. Move the time outside the change, \
             give the schedule a zone without daylight saving (such as UTC), or give the job a schedule of its own",
            self.where_,
            self.zone_name(),
            old[0],
            old[1],
            old[2],
            old[3],
            old[4],
            new[3],
            new[4],
            self.scheduler,
            self.stamp(due.unwrap_or(0))
        ))
    }
}
