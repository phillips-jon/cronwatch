//! A schedule of the `cron` crate's (the `cron` feature), which apalis-cron
//! runs itself: declared from its source text once it is checked against
//! the crate's own fire times.

use chrono::{DateTime, Utc};
use cronwatch::JobOptions;
use cronwatch::bridge::{self, Entry, ScheduleError};

use super::{Watcher, quote};
use apalis_cron::CronScheduler;

impl Watcher {
    /// Declares the job `name` with a schedule of the `cron` crate's read in
    /// `tz`, and gives the backend for its worker, which apalis-cron runs on
    /// the `cron` crate's fire times. The source text is declared as it is
    /// once CronWatch is found to expect runs exactly when the `cron` crate
    /// makes them ([`cronwatch::bridge::check_fires`]); otherwise (the `cron`
    /// crate counts the days of the week from 1, Sunday, and matches a day
    /// of the month and of the week together) the job is watched without a
    /// schedule and the difference reported once. A name or option
    /// CronWatch refuses is an error.
    pub fn cron_schedule(
        &self,
        name: &str,
        schedule: cron::Schedule,
        tz: chrono_tz::Tz,
        options: JobOptions,
    ) -> Result<CronScheduler<cron::Schedule, chrono_tz::Tz>, cronwatch::Error> {
        let label = format!("apalis-cron worker {}", quote(name));
        let mut entry = Entry { name: name.into(), label: label.clone(), options, ..Entry::default() };
        match convert(&schedule, tz, &format!("cronwatch: {label}"), Utc::now().timestamp_millis()) {
            Ok((text, zone)) => {
                entry.schedule = text;
                entry.timezone = zone;
            }
            Err(e) => entry.problem = Some(e.to_string()),
        }
        self.add(entry)?;
        Ok(CronScheduler::new(schedule).with_timezone(tz))
    }
}

/// The schedule text and zone CronWatch reads a `cron` crate schedule as,
/// checked against the crate's own fire times.
pub(crate) fn convert(
    schedule: &cron::Schedule,
    tz: chrono_tz::Tz,
    where_: &str,
    now: i64,
) -> Result<(String, String), ScheduleError> {
    let text = schedule.source().trim().to_string();
    let zone = if tz == chrono_tz::UTC { "UTC".to_string() } else { tz.name().to_string() };
    let fields: Vec<&str> = text.split_whitespace().collect();
    let daily = fields.len() >= 6 && fields[3..].iter().all(|f| matches!(*f, "*" | "?"));
    bridge::check_fires(&runs(schedule.clone(), tz), &text, &zone, where_, "the cron crate", daily, now)?;
    Ok((text, zone))
}

/// The `cron` crate's own runs of `schedule` in `tz`.
fn runs(schedule: cron::Schedule, tz: chrono_tz::Tz) -> impl Fn(i64, Option<i64>) -> Result<Vec<i64>, ScheduleError> {
    move |start, end| {
        let at = |ms: i64| DateTime::from_timestamp_millis(ms).map(|t| t.with_timezone(&tz));
        let mut before = None;
        for lookback in
            [3_600_000i64, 86_400_000, 8 * 86_400_000, 32 * 86_400_000, 367 * 86_400_000, 5 * 366 * 86_400_000]
        {
            let Some(from) = at(start - lookback) else {
                continue;
            };
            for t in schedule.after(&from) {
                if t.timestamp_millis() > start {
                    break;
                }
                before = Some(t);
            }
            if before.is_some() {
                break;
            }
        }
        let Some(before) = before else {
            return Err(bridge::never_fires("the cron crate finds no fire time in the five years before it"));
        };
        let mut out = vec![before.timestamp_millis()];
        for t in schedule.after(&before) {
            out.push(t.timestamp_millis());
            if (end.is_none() && out.len() > bridge::SAMPLE_RUNS) || end.is_some_and(|e| t.timestamp_millis() > e) {
                break;
            }
        }
        Ok(out)
    }
}
