//! A port of croner 10, the cron library the SDK uses: its reading of an
//! expression (CronPattern, with its checks and its messages word for word)
//! and its walk to the next matching time (CronDate), habits included: a
//! day the month does not have rolls over, a wall-clock time in a
//! spring-forward gap moves forward by the gap, and a time that happens
//! twice is the earlier one. The names and the order of every step follow
//! croner's source, as the Go port's `internal/schedule/cron`, the Python
//! port's `_cron.py` and the PHP port's `src/Cron` do, so the five agree on
//! every expression they read, every one they refuse and every fire time.
//!
//! Where it cannot match croner:
//!
//! - A date no month has (`0 0 30 2 *`) makes croner, which walks by
//!   recursion a year at a time, run out of stack before the year 3000.
//!   This port walks in a loop and answers that the expression never fires.
//! - Croner reads a string with a colon after its first character as a
//!   one-time date, through JavaScript's lenient `Date.parse`. This port
//!   refuses every such string: one that looks like an ISO date with
//!   "CronPattern: a one-time date is not supported by the Rust port",
//!   anything else with the message croner gives for text `Date.parse`
//!   cannot read, "Invalid ISO8601 passed to timezone parser.".

mod date;
mod pattern;
mod zone;

use jiff::tz::TimeZone;

use date::Date;
pub(crate) use pattern::{Error, Pattern};
pub(crate) use zone::{load_zone, offset};

/// What the schedule uses of croner's Cron: an expression that schedules
/// nothing and only answers `next_runs`.
#[derive(Clone, Debug)]
pub(crate) struct Cron {
    pattern: Pattern,
    tz: TimeZone,
}

/// `/^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}/`, the start of an ISO date and time.
fn is_iso_date(text: &str) -> bool {
    let b = text.as_bytes();
    let digits = |r: std::ops::Range<usize>| r.clone().all(|i| b.get(i).is_some_and(u8::is_ascii_digit));
    b.len() >= 16
        && digits(0..4)
        && b[4] == b'-'
        && digits(5..7)
        && b[7] == b'-'
        && digits(8..10)
        && (b[10] == b'T' || b[10] == b' ')
        && digits(11..13)
        && b[13] == b':'
        && digits(14..16)
}

impl Cron {
    /// Reads an expression, to be walked in the zone `tz`. Its errors are
    /// croner's, word for word.
    pub(crate) fn new(text: &str, tz: TimeZone) -> Result<Cron, Error> {
        if text.len() > 1 && text.as_bytes()[1..].contains(&b':') {
            // Croner reads a string with a colon after its first character as
            // a one-time date to fire at, not as a cron expression.
            if is_iso_date(text) {
                return Err("CronPattern: a one-time date is not supported by the Rust port".into());
            }
            return Err("Invalid ISO8601 passed to timezone parser.".into());
        }
        Ok(Cron { pattern: Pattern::new(text)?, tz })
    }

    /// The zone the expression is walked in.
    pub(crate) fn zone(&self) -> &TimeZone {
        &self.tz
    }

    /// Croner's `nextRuns`: up to `count` fires after `start` (epoch ms),
    /// each found from the one before. Fewer when the expression stops
    /// firing.
    pub(crate) fn next_runs(&self, count: usize, start: i64) -> Vec<i64> {
        let mut runs = Vec::with_capacity(count);
        let mut d = Date::from_ms(start, &self.tz);
        for _ in 0..count {
            match d.increment(&self.pattern) {
                Ok(true) => runs.push(d.time_ms(&self.tz)),
                _ => break,
            }
        }
        runs
    }
}

#[cfg(test)]
mod tests;
