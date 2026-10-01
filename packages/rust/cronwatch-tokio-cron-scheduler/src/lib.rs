//! CronWatch for [tokio-cron-scheduler](https://docs.rs/tokio-cron-scheduler):
//! its jobs declared as CronWatch jobs with their schedules, and every run
//! recorded, so a job that fails, runs late, never runs, gets stuck or runs
//! slow is reported.
//!
//! tokio-cron-scheduler names a job only by a UUID and runs a closure that
//! returns nothing, so its notifications cannot tell a failed run from a
//! good one. The [`Watcher`] stands in for its constructors instead: each
//! job is made with a name, and its closure returns a `Result`.
//!
//! ```no_run
//! use cronwatch::{Client, JobOptions};
//! use cronwatch_tokio_cron_scheduler::{Options, Watcher};
//! use std::time::Duration;
//! use tokio_cron_scheduler::JobScheduler;
//!
//! # async fn build_report() -> Result<String, std::io::Error> { Ok(String::new()) }
//! # async fn example() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
//! let cw = Client::builder().build()?;
//! let watcher = Watcher::new(&cw, Options::default());
//! let scheduler = JobScheduler::new().await?;
//! scheduler
//!     .add(watcher.job(
//!         "nightly-report",
//!         "0 0 2 * * *", // seconds first, as tokio-cron-scheduler reads it
//!         "UTC",
//!         |job| async move {
//!             let path = build_report().await?;
//!             job.log(format!("Report written: {path}"));
//!             Ok::<_, std::io::Error>(())
//!         },
//!         JobOptions::new().grace("15m"),
//!     )?)
//!     .await?;
//! scheduler.add(watcher.check_job(Duration::from_secs(60))?).await?;
//! watcher.follow(&scheduler);
//! scheduler.start().await?;
//! # Ok(())
//! # }
//! ```
//!
//! # Schedules
//!
//! The expression is given to tokio-cron-scheduler and to CronWatch
//! unchanged: both read six fields seconds first (`sec min hour day month
//! weekday`). They are read by two parsers by the same author, the `croner`
//! crate for the scheduler and the port of croner (JavaScript) for
//! CronWatch, which differ in places (tokio-cron-scheduler matches a day of
//! the month and a day of the week together, where croner matches either),
//! so each schedule is checked against the scheduler's own fire times
//! ([`cronwatch::bridge::check_fires`]); one that differs is reported once
//! and its job watched without a schedule, so it is never reported missed.
//!
//! tokio-cron-scheduler 0.15 reads a job made in a zone at the offset the
//! zone had when the job was made (its `time_offset_seconds`): after the
//! first run, a job in `America/New_York` made in summer runs at -04:00 all
//! winter, until the process restarts. CronWatch expects what the scheduler
//! does: a zone whose offset changes in the next five years is declared at
//! that fixed offset (`Etc/GMT+4`, or `+05:30` for an offset in part of an
//! hour), and the move is reported once. Give such a job a zone without
//! daylight saving, such as UTC, to keep it at one time of day.
//!
//! [`Watcher::repeated`] is `Job::new_repeated_async`, declared `every
//! <interval>` in whole seconds, as the scheduler counts it.
//!
//! # Jobs gone
//!
//! A job removed from the scheduler keeps its runs and is declared again
//! without its schedule, so it is never reported missed: at once when the
//! watcher follows the scheduler ([`Watcher::follow`]), else at the next
//! [`Watcher::sync`], which the check job runs. Across deploys, a sync
//! also declares again without its schedule each job of this app's the
//! store holds with a schedule that no job made here has
//! ([`cronwatch::bridge::Watch::unschedule`]).
//!
//! Jobs are tagged `tokio-cron-scheduler` and `tokio-cron-scheduler:<app>`,
//! the app named by [`Options::app`], else `$CRONWATCH_APP_ID`, else the
//! executable's file name, so two apps sharing a store never declare each
//! other's jobs without a schedule.
#![forbid(unsafe_code)]

use std::fmt;
use std::future::Future;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::time::Duration;

use chrono::{DateTime, FixedOffset, Offset, TimeZone, Utc};
use croner::Cron;
use croner::parser::{CronParser, Seconds};
use cronwatch::bridge::{self, Entry, ScheduleError, Watch};
use cronwatch::{Client, JobContext, JobOptions, RunOptions};
use tokio::sync::broadcast::error::RecvError;
use tokio_cron_scheduler::{Job, JobScheduler, JobSchedulerError};
use uuid::Uuid;

/// The tag every job this crate declares carries.
pub const TAG: &str = "tokio-cron-scheduler";
/// The trigger of the runs it records.
pub const TRIGGER: &str = "tokio-cron-scheduler";
/// How messages name the scheduler.
const SCHEDULER: &str = "tokio-cron-scheduler";
/// Bounds a sync the watcher starts itself (the store's reads and writes),
/// so a store that hangs never holds its task for good.
const SYNC_TIMEOUT: Duration = Duration::from_secs(30);

/// Options for a [`Watcher`]. `#[non_exhaustive]`, so a release can add an
/// option: start from [`Options::new`] and set what you need.
#[derive(Clone, Debug, Default)]
#[non_exhaustive]
pub struct Options {
    /// Names the app in its tag. Default `$CRONWATCH_APP_ID`, else the
    /// executable's file name ([`cronwatch::bridge::app_name`]).
    pub app: Option<String>,
    /// Job options for every job, before its schedule and its own options.
    pub defaults: JobOptions,
}

impl Options {
    /// The defaults: the app from `$CRONWATCH_APP_ID` or the executable's
    /// name, and no job options.
    pub fn new() -> Options {
        Options::default()
    }

    /// Sets `app`, the name in this app's tag.
    pub fn app(mut self, app: impl Into<String>) -> Self {
        self.app = Some(app.into());
        self
    }

    /// Sets `defaults`, the job options for every job.
    pub fn defaults(mut self, defaults: JobOptions) -> Self {
        self.defaults = defaults;
        self
    }
}

/// Why a job could not be made.
#[derive(Debug)]
#[non_exhaustive]
pub enum Error {
    /// tokio-cron-scheduler refused it (a schedule it cannot read).
    Scheduler(JobSchedulerError),
    /// The zone is not one tokio-cron-scheduler knows (chrono-tz's names).
    Timezone(String),
    /// CronWatch refused the name or an option, with the SDK's message, so
    /// its runs could not be recorded.
    Invalid(cronwatch::Error),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Scheduler(e) => write!(f, "tokio-cron-scheduler refused the job: {e}"),
            Error::Timezone(zone) => write!(f, "timezone {zone:?} is not an IANA timezone"),
            Error::Invalid(e) => fmt::Display::fmt(e, f),
        }
    }
}

impl std::error::Error for Error {}

impl From<JobSchedulerError> for Error {
    fn from(e: JobSchedulerError) -> Self {
        Error::Scheduler(e)
    }
}

/// Watches the jobs of one tokio-cron-scheduler scheduler. A cheap handle
/// (an `Arc` inside), safe to use from many tasks at once.
#[derive(Clone)]
pub struct Watcher {
    shared: Arc<Shared>,
}

impl fmt::Debug for Watcher {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Watcher").field("watch", &self.shared.watch).finish_non_exhaustive()
    }
}

struct Shared {
    cw: Client,
    watch: Watch,
    defaults: JobOptions,
    tracked: Mutex<Vec<Tracked>>,
}

/// A job made through the watcher.
struct Tracked {
    uuid: Uuid,
    entry: Entry,
    /// Seen in a scheduler, so its absence means it was removed.
    seen: bool,
    gone: bool,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

impl Watcher {
    /// A watcher declaring jobs on `cw`.
    pub fn new(cw: &Client, options: Options) -> Watcher {
        Watcher {
            shared: Arc::new(Shared {
                cw: cw.clone(),
                watch: Watch::new(cw, TAG, options.app.as_deref(), SCHEDULER),
                defaults: options.defaults,
                tracked: Mutex::new(Vec::new()),
            }),
        }
    }

    /// The bridge watch the jobs are declared through.
    pub fn watch(&self) -> &Watch {
        &self.shared.watch
    }

    /// `Job::new_async_tz`: a cron job named `name` that runs `f` on
    /// `schedule` (six fields, seconds first) in `timezone` (an IANA name;
    /// `""` or `"UTC"` for UTC, tokio-cron-scheduler's default), declared as
    /// a CronWatch job with that schedule and `options`. Each run is
    /// recorded: an `Err` from `f` fails it, a `String` it returns is its
    /// output when nothing was logged, and a panic is recorded as a failed
    /// run before it goes on to tokio. The returned job is the app's to give
    /// to `JobScheduler::add`. A name or option CronWatch refuses is an
    /// error, as is a schedule or zone the scheduler refuses; a schedule
    /// CronWatch reads differently is reported once and the job watched
    /// without it.
    pub fn job<F, Fut, T, E>(
        &self,
        name: &str,
        schedule: &str,
        timezone: &str,
        f: F,
        options: JobOptions,
    ) -> Result<Job, Error>
    where
        F: Fn(JobContext) -> Fut + Send + Sync + 'static,
        Fut: Future<Output = Result<T, E>> + Send + 'static,
        T: Send + 'static,
        E: fmt::Display + Send + 'static,
    {
        let label = format!("{SCHEDULER} job {}", quote(name));
        self.validate(name, &options)?;
        let tz = zone(timezone)?;
        let cell = Arc::new(OnceLock::new());
        let run = self.runner(name, cell.clone(), f);
        let job = Job::new_async_tz(schedule, tz, move |_, _| run())?;
        let mut entry = Entry { name: name.into(), label: label.clone(), options, ..Entry::default() };
        match convert(schedule, tz, &format!("cronwatch: {label}"), Utc::now()) {
            Ok(converted) => {
                entry.schedule = schedule.to_string();
                entry.timezone = converted.zone;
                entry.problem = converted.note;
            }
            Err(e) => entry.problem = Some(e.to_string()),
        }
        self.track(job.guid(), entry, &cell);
        Ok(job)
    }

    /// `Job::new_repeated_async`: a job named `name` that runs `f` every
    /// `every` (whole seconds, as tokio-cron-scheduler counts it), declared
    /// `every <interval>`. Runs are recorded as [`job`](Self::job)'s are.
    pub fn repeated<F, Fut, T, E>(&self, name: &str, every: Duration, f: F, options: JobOptions) -> Result<Job, Error>
    where
        F: Fn(JobContext) -> Fut + Send + Sync + 'static,
        Fut: Future<Output = Result<T, E>> + Send + 'static,
        T: Send + 'static,
        E: fmt::Display + Send + 'static,
    {
        let label = format!("{SCHEDULER} job {}", quote(name));
        self.validate(name, &options)?;
        let cell = Arc::new(OnceLock::new());
        let run = self.runner(name, cell.clone(), f);
        let job = Job::new_repeated_async(every, move |_, _| run())?;
        let whole = Duration::from_secs(every.as_secs());
        let mut entry = Entry { name: name.into(), label: label.clone(), options, ..Entry::default() };
        if whole < Duration::from_secs(1) {
            entry.problem = Some(format!(
                "cronwatch: {label} runs every {every:?}, which tokio-cron-scheduler counts in whole seconds; CronWatch watches intervals of one second or more"
            ));
        } else {
            entry.schedule = bridge::every_text(whole);
        }
        self.track(job.guid(), entry, &cell);
        Ok(job)
    }

    /// What `Client::job` would refuse, before anything is made.
    fn validate(&self, name: &str, options: &JobOptions) -> Result<(), Error> {
        bridge::validate(name, &self.shared.defaults.clone().merge(options.clone())).map_err(Error::Invalid)
    }

    /// Declares a job made here, and every job made before it, with the
    /// jobs removed since declared again without their schedule, and keeps
    /// the declared job where the job's runs find it when nothing else is
    /// declared under its name.
    fn track(&self, uuid: Uuid, mut entry: Entry, cell: &OnceLock<cronwatch::Job>) {
        entry.defaults = self.shared.defaults.clone();
        let (name, options) = (entry.name.clone(), entry.defaults.clone().merge(entry.options.clone()));
        lock(&self.shared.tracked).push(Tracked { uuid, entry, seen: false, gone: false });
        self.declare();
        let declared = self.shared.watch.job(&name).or_else(|| {
            // Validated above, so only a client that changed its mind
            // gets here: declared without the schedule, runs still kept.
            self.shared.cw.job(&name, self.shared.watch.tagged(&name, options)).ok()
        });
        if let Some(job) = declared {
            let _ = cell.set(job);
        }
    }

    /// Declares the jobs made here that are not gone. The list is read and
    /// declared under one lock, so two declarations at once (two jobs made
    /// on two threads, a job made while a sync runs) never land in the
    /// wrong order, the older list taking the newer job for gone.
    fn declare(&self) {
        let tracked = lock(&self.shared.tracked);
        let entries: Vec<Entry> = tracked.iter().filter(|t| !t.gone).map(|t| t.entry.clone()).collect();
        self.shared.watch.declare(&entries);
    }

    /// The closure tokio-cron-scheduler runs: `f` inside a recorded run of
    /// the job declared under `name`, else unwatched.
    fn runner<F, Fut, T, E>(
        &self,
        name: &str,
        made: Arc<OnceLock<cronwatch::Job>>,
        f: F,
    ) -> impl Fn() -> std::pin::Pin<Box<dyn Future<Output = ()> + Send>> + Send + Sync + 'static
    where
        F: Fn(JobContext) -> Fut + Send + Sync + 'static,
        Fut: Future<Output = Result<T, E>> + Send + 'static,
        T: Send + 'static,
        E: fmt::Display + Send + 'static,
    {
        let f = Arc::new(f);
        let watch = self.shared.watch.clone();
        let name = name.to_string();
        move || {
            let (f, watch, name, made) = (f.clone(), watch.clone(), name.clone(), made.clone());
            Box::pin(async move {
                // The job as declared now (its schedule may have changed
                // since), else as it was made.
                match watch.job(&name).or_else(|| made.get().cloned()) {
                    Some(job) => {
                        let _ = job.run_with(RunOptions::new().trigger(TRIGGER), |jc| f(jc)).await;
                    }
                    // Only a client that refused the job after it was
                    // validated gets here; the function takes a run's
                    // context, so it cannot run without one. Said once
                    // rather than skipped in silence.
                    None => watch.report_once(
                        &format!(
                            "cronwatch: {SCHEDULER} job {} did not run: no CronWatch job is declared under its name",
                            quote(&name)
                        ),
                        SCHEDULER,
                    ),
                }
            })
        }
    }

    /// Follows `scheduler`: a job made here that it removes is declared again
    /// without its schedule at once (with a sync of the store, within 30
    /// seconds), rather than at the next [`sync`](Self::sync), and one it
    /// adds again after that is declared with its schedule again the same
    /// way. It spawns a
    /// task on the current tokio runtime (call it inside one, as
    /// `JobScheduler::new` is), which holds the scheduler and so runs until
    /// the returned handle aborts it or the runtime ends:
    /// `JobScheduler::shutdown` does not end it, since it closes none of the
    /// scheduler's channels (nor removes any job, so none is taken for
    /// gone).
    pub fn follow(&self, scheduler: &JobScheduler) -> tokio::task::JoinHandle<()> {
        let context = scheduler.context();
        let mut created = context.job_created_tx.subscribe();
        let mut deleted = context.job_deleted_tx.subscribe();
        let watcher = self.clone();
        let scheduler = scheduler.clone();
        tokio::spawn(async move {
            loop {
                tokio::select! {
                    made = created.recv() => match made {
                        Ok(Ok(uuid)) => {
                            if watcher.saw(uuid) {
                                watcher.sync_within(&scheduler).await;
                            }
                        }
                        Ok(Err(_)) => {}
                        Err(RecvError::Lagged(_)) => watcher.sync_within(&scheduler).await,
                        Err(RecvError::Closed) => return,
                    },
                    gone = deleted.recv() => match gone {
                        Ok(Ok(uuid)) => {
                            if watcher.removed(uuid) {
                                watcher.sync_within(&scheduler).await;
                            }
                        }
                        Ok(Err(_)) => {}
                        Err(RecvError::Lagged(_)) => watcher.sync_within(&scheduler).await,
                        Err(RecvError::Closed) => return,
                    },
                }
            }
        })
    }

    /// Marks a job made here as in the scheduler, and says whether it had
    /// been removed: one added again (a clone of its `Job` keeps its uuid)
    /// is to be declared with its schedule again.
    fn saw(&self, uuid: Uuid) -> bool {
        let mut tracked = lock(&self.shared.tracked);
        match tracked.iter_mut().find(|t| t.uuid == uuid) {
            Some(t) => {
                t.seen = true;
                std::mem::replace(&mut t.gone, false)
            }
            None => false,
        }
    }

    /// Marks a job made here as removed, and says whether it was one.
    fn removed(&self, uuid: Uuid) -> bool {
        let mut tracked = lock(&self.shared.tracked);
        match tracked.iter_mut().find(|t| t.uuid == uuid) {
            Some(t) => {
                t.gone = true;
                true
            }
            None => false,
        }
    }

    /// [`sync`](Self::sync) within `SYNC_TIMEOUT`, its problems reported.
    async fn sync_within(&self, scheduler: &JobScheduler) {
        let err = match tokio::time::timeout(SYNC_TIMEOUT, self.sync(scheduler)).await {
            Ok(Ok(())) => return,
            Ok(Err(err)) => err,
            Err(_) => cronwatch::Error::Other(format!(
                "the sync took longer than {} seconds; gave up",
                SYNC_TIMEOUT.as_secs()
            )),
        };
        self.shared.cw.report_error(err, SCHEDULER);
    }

    /// Declares the jobs made here that `scheduler` still has, and again
    /// without its schedule each one it no longer has (removed since it was
    /// seen there) and each job of this app's the store holds with a
    /// schedule that no job made here has (taken out since a process
    /// declared it). The check job runs it before each check. Everything is
    /// written to the store before it returns.
    pub async fn sync(&self, scheduler: &JobScheduler) -> Result<(), cronwatch::Error> {
        let uuids: Vec<Uuid> = lock(&self.shared.tracked).iter().map(|t| t.uuid).collect();
        let mut scheduler = scheduler.clone();
        for uuid in uuids {
            let present = match scheduler.next_tick_for_job(uuid).await {
                Ok(next) => next.is_some(),
                Err(_) => continue,
            };
            let mut tracked = lock(&self.shared.tracked);
            if let Some(t) = tracked.iter_mut().find(|t| t.uuid == uuid) {
                if present {
                    t.seen = true;
                    t.gone = false;
                } else if t.seen {
                    t.gone = true;
                }
            }
        }
        self.declare();
        self.shared.watch.settle().await;
        self.shared.watch.unschedule().await.map(|_| ())
    }

    /// A job that runs [`sync`](Self::sync) and a CronWatch check every
    /// `every` (a minute is a good interval), for a service that does not
    /// call `Client::start`. Its runs are never a job; a failure is
    /// reported to the client's error handler.
    pub fn check_job(&self, every: Duration) -> Result<Job, Error> {
        let watcher = self.clone();
        Ok(Job::new_repeated_async(every, move |_, scheduler| {
            let watcher = watcher.clone();
            Box::pin(async move {
                watcher.sync_within(&scheduler).await;
                if let Err(err) = watcher.shared.cw.check().await {
                    watcher.shared.cw.report_error(err, SCHEDULER);
                }
            })
        })?)
    }

    /// Waits until what the watcher declared has been written to the store,
    /// for tests and a clean exit.
    pub async fn wait(&self) {
        self.shared.watch.settle().await;
    }
}

/// `name` as JSON writes it, for messages.
fn quote(name: &str) -> String {
    cronwatch::js::stringify(&cronwatch::js::Value::from(name))
}

/// The chrono-tz zone an IANA name names, without regard to case; `""` is
/// UTC, tokio-cron-scheduler's default.
fn zone(name: &str) -> Result<chrono_tz::Tz, Error> {
    if name.is_empty() {
        return Ok(chrono_tz::UTC);
    }
    chrono_tz::Tz::from_str_insensitive(name).map_err(|_| Error::Timezone(name.to_string()))
}

/// A schedule as CronWatch reads it, and a note to report once.
#[derive(Debug, PartialEq)]
struct Converted {
    zone: String,
    note: Option<String>,
}

/// How the zone tokio-cron-scheduler will read `schedule` in is named for
/// CronWatch, checked against the scheduler's own fire times.
fn convert(schedule: &str, tz: chrono_tz::Tz, where_: &str, now: DateTime<Utc>) -> Result<Converted, ScheduleError> {
    let cron = parser().parse(schedule).map_err(|e| {
        ScheduleError::new(format!("{where_} is {}, which tokio-cron-scheduler cannot read: {e}", quote(schedule)))
    })?;
    let offset = tz.offset_from_utc_datetime(&now.naive_utc()).fix();
    let (zone, note) = if steady(tz, now) {
        (if tz == chrono_tz::UTC { "UTC".to_string() } else { tz.name().to_string() }, None)
    } else {
        let fixed = offset_name(offset.local_minus_utc());
        let note = format!(
            "{where_} is in {}, which tokio-cron-scheduler reads at the offset it had when the job was made ({}) until the process restarts, so its runs move when the clocks change; CronWatch expects them at {fixed} too. Give the job a zone without daylight saving, such as UTC, to keep it at one time of day",
            tz.name(),
            offset_text(offset.local_minus_utc())
        );
        (fixed, Some(note))
    };
    let daily = daily(schedule);
    bridge::check_fires(&runs(cron, offset), schedule, &zone, where_, SCHEDULER, daily, now.timestamp_millis())?;
    Ok(Converted { zone, note })
}

/// The parser tokio-cron-scheduler 0.15 reads a schedule with.
fn parser() -> CronParser {
    CronParser::builder().seconds(Seconds::Required).dom_and_dow(true).build()
}

/// Whether a zone's offset holds for the next five years.
fn steady(tz: chrono_tz::Tz, now: DateTime<Utc>) -> bool {
    let first = tz.offset_from_utc_datetime(&now.naive_utc()).fix();
    (0..5 * 53).all(|week| {
        let at = now + chrono::Duration::weeks(week);
        tz.offset_from_utc_datetime(&at.naive_utc()).fix() == first
    })
}

/// A fixed offset as a zone every port reads: `UTC`, `Etc/GMT+4` for
/// -04:00 (the IANA names count west), or `+05:30` for part of an hour.
fn offset_name(seconds: i32) -> String {
    match seconds {
        0 => "UTC".into(),
        s if s % 3600 == 0 => format!("Etc/GMT{:+}", -s / 3600),
        s => offset_text(s),
    }
}

fn offset_text(seconds: i32) -> String {
    let sign = if seconds < 0 { '-' } else { '+' };
    let s = seconds.abs();
    format!("{sign}{:02}:{:02}", s / 3600, s % 3600 / 60)
}

/// Whether a cron names no day or month (every day alike), so the clock
/// changes of one kind are walked once.
fn daily(schedule: &str) -> bool {
    let fields: Vec<&str> = schedule.split_whitespace().collect();
    fields.len() >= 6 && fields[3..].iter().all(|f| matches!(*f, "*" | "?"))
}

/// tokio-cron-scheduler's own runs of `cron` read at `offset`, as its tick
/// loop asks them: each the first strictly after the last.
fn runs(cron: Cron, offset: FixedOffset) -> impl Fn(i64, Option<i64>) -> Result<Vec<i64>, ScheduleError> {
    move |start, end| {
        let at = |ms: i64| DateTime::from_timestamp_millis(ms).map(|t| t.with_timezone(&offset));
        let next = |t: &DateTime<FixedOffset>| cron.find_next_occurrence(t, false).ok();
        let mut before = None;
        for lookback in
            [3_600_000i64, 86_400_000, 8 * 86_400_000, 32 * 86_400_000, 367 * 86_400_000, 5 * 366 * 86_400_000]
        {
            let Some(from) = at(start - lookback) else {
                continue;
            };
            let mut found = next(&from);
            while let Some(t) = found.filter(|t| t.timestamp_millis() <= start) {
                before = Some(t);
                found = next(&t);
            }
            if before.is_some() {
                break;
            }
        }
        let Some(before) = before else {
            return Err(bridge::never_fires("tokio-cron-scheduler finds no fire time in the five years before it"));
        };
        let mut out = vec![before.timestamp_millis()];
        let mut current = before;
        while let Some(t) = next(&current) {
            out.push(t.timestamp_millis());
            current = t;
            if (end.is_none() && out.len() > bridge::SAMPLE_RUNS) || end.is_some_and(|e| t.timestamp_millis() > e) {
                break;
            }
        }
        Ok(out)
    }
}

#[cfg(test)]
mod tests;

// The README's examples, compiled as doc tests.
#[cfg(doctest)]
#[doc = include_str!("../README.md")]
struct Readme;
