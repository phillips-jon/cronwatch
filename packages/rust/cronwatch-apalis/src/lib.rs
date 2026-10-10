//! CronWatch for [apalis](https://docs.rs/apalis) 1.0 (its release
//! candidates): each attempt of a worker's tasks recorded as a run, through
//! a tower layer, and apalis-cron given CronWatch's own schedules, so a job
//! that fails, runs late, never runs, gets stuck, or runs slow is reported.
//!
//! Unlike the rest of the workspace, this crate stays below 1.0 while apalis
//! 1.0 is a release candidate: it is left out of 1.0's promise, and a
//! release of it may change its API to follow a new candidate. It will join
//! the promise once apalis 1.0 is final.
//!
//! ```no_run
//! use apalis_core::worker::builder::WorkerBuilder;
//! use apalis_cron::Tick;
//! use cronwatch::{Client, JobOptions};
//! use cronwatch_apalis::{Options, Watcher};
//! use std::time::Duration;
//!
//! # async fn example() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
//! async fn nightly_report(_tick: Tick) -> Result<(), std::io::Error> {
//!     if let Some(job) = cronwatch::current() {
//!         job.log("Report written");
//!     }
//!     Ok(())
//! }
//!
//! let cw = Client::builder().build()?;
//! let watcher = Watcher::new(&cw, Options::default());
//! let worker = WorkerBuilder::new("nightly-report")
//!     .backend(watcher.cron("nightly-report", "0 2 * * *", "Europe/London", JobOptions::new().grace("15m"))?)
//!     // .retry(RetryPolicy::retries(3)) before it, so each attempt is a run
//!     .layer(watcher.layer())
//!     .build(nightly_report);
//! tokio::spawn(watcher.check_worker(Duration::from_secs(60))?.run());
//! worker.run().await?;
//! # Ok(())
//! # }
//! ```
//!
//! # Schedules
//!
//! [`Watcher::cron`] declares a job and gives apalis-cron a [`Schedule`]
//! that is CronWatch's own reading of it (the port of croner the SDK uses),
//! so the worker runs on exactly the fire times CronWatch expects and no
//! conversion or check is needed. [`schedule`] is the same schedule without
//! a declaration. With the `cron` feature, [`Watcher::cron_schedule`] takes
//! a schedule of the `cron` crate's, which apalis-cron runs itself, and
//! declares it from its source text once it is checked against the `cron`
//! crate's own fire times ([`cronwatch::bridge::check_fires`]); one that
//! differs (the `cron` crate counts the days of the week from 1, Sunday, and
//! matches both days) is reported once and watched without a schedule.
//!
//! # Runs and retries
//!
//! [`Watcher::layer`] is a tower layer for `WorkerBuilder::layer` that
//! records each attempt of the worker's tasks as a run (trigger `apalis`)
//! of the job named after the worker ([`Watcher::layer_for`] names it),
//! with the run's `JobContext` as the task-local, so the handler logs and
//! adds metrics through [`cronwatch::current`]. Added after `.retry(...)`,
//! it sits inside the retry layer, so every attempt is a run of its own, as
//! the gem's Sidekiq rules have it: failing attempts open one failed alert
//! and the one that succeeds closes it, and `failures_before_alert` rides
//! through retries. A panic is a failed run, then carries on to apalis's
//! `catch_panic` layer or the task. An attempt apalis gives back without
//! failing (a `DeferredError` or a `RetryAfterError`, which put the task
//! back as pending, or a task cancelled while it ran) is taken back rather
//! than judged ([`cronwatch::Job::run_or_discard`]).
//!
//! It works over any backend: a worker on apalis's Postgres, MySQL, SQLite,
//! or Redis storage records its tasks the same way. A worker whose job this
//! process did not declare (queued tasks, or a worker in a process of its
//! own while another process schedules) declares it from the definition the
//! store holds when it is this app's, so the schedule another process
//! stored is kept, else with [`Options::defaults`] and its entry in
//! [`Options::jobs`].
//!
//! # Jobs gone and the check
//!
//! [`Watcher::check_worker`] is a cron worker that runs [`Watcher::sync`]
//! and a CronWatch check. The sync declares again without its schedule
//! each job of this app's the store holds with a schedule that no worker
//! made here has (taken out since a process declared it). Its runs are
//! never a job. Jobs are tagged `apalis` and `apalis:<app>`, the app named
//! by [`Options::app`], else `$CRONWATCH_APP_ID`, else the executable's
//! file name.
#![forbid(unsafe_code)]

use std::any::Any;
use std::collections::HashMap;
use std::fmt;
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex, MutexGuard};
use std::task::{Context, Poll};
use std::time::Duration;

use apalis_core::error::{AbortError, BoxDynError, DeferredError, RetryAfterError};
use apalis_core::layers::Identity;
use apalis_core::task::Task;
use apalis_core::worker::Worker;
use apalis_core::worker::builder::WorkerBuilder;
use apalis_core::worker::context::WorkerContext;
use apalis_core::worker::lifecycle::TaskLifecycleError;
use apalis_cron::{CronScheduler, Tick};
use cronwatch::bridge::{self, Entry, Watch};
use cronwatch::{Client, JobOptions, RunOptions};

/// The tag every job this crate declares carries.
pub const TAG: &str = "apalis";
/// The trigger of the runs it records.
pub const TRIGGER: &str = "apalis";
/// The name of the check worker, never a job.
pub const CHECK_WORKER: &str = "cronwatch-check";
const SCHEDULER: &str = "apalis-cron";
/// Bounds a sync the check worker runs, so a store that hangs never holds
/// it for good.
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
    /// Options for the jobs of workers this process declares no schedule
    /// for (queued tasks), by the worker's name, used when the store holds
    /// no definition of this app's for it.
    pub jobs: HashMap<String, JobOptions>,
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

    /// Adds to `jobs`: the options for the jobs of the worker `name`.
    pub fn job(mut self, name: impl Into<String>, options: JobOptions) -> Self {
        self.jobs.insert(name.into(), options);
        self
    }
}

/// Watches one app's apalis workers. A cheap handle (an `Arc` inside), safe
/// to use from many tasks at once.
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
    options: Options,
    entries: Mutex<Vec<Entry>>,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// A schedule as CronWatch reads it (a cron in a zone, or `every
/// <duration>`), for apalis-cron's `CronScheduler`: it ticks on exactly the
/// times CronWatch expects runs.
#[derive(Clone, Debug)]
pub struct Schedule {
    schedule: bridge::Schedule,
    last: Option<i64>,
}

/// CronWatch's reading of `expr` in `zone` (an IANA name, `""` for the
/// process's own zone) for apalis-cron, with the SDK's messages for what it
/// refuses. It declares nothing; [`Watcher::cron`] declares the job too.
pub fn schedule(expr: &str, zone: &str) -> Result<Schedule, cronwatch::Error> {
    Ok(Schedule { schedule: bridge::Schedule::parse(expr, zone)?, last: None })
}

impl Schedule {
    /// The next tick strictly after `now_ms` and after the last one given,
    /// in epoch milliseconds.
    fn next_after(&mut self, now_ms: i64) -> Option<i64> {
        let from = self.last.map_or(now_ms, |last| last.max(now_ms));
        let next = self.schedule.fire_after(from)?;
        self.last = Some(next);
        Some(next)
    }
}

impl<Tz> apalis_cron::Schedule<Tz> for Schedule {
    fn next_tick(&mut self, _: &Tz) -> Option<Tick<Tz>> {
        let now =
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_millis() as i64);
        // Ticks are whole seconds; croner's fires are too, and an interval
        // is rounded up so the tick is never before the fire.
        self.next_after(now).map(|ms| Tick::new(ms.div_euclid(1000) as u64 + u64::from(ms.rem_euclid(1000) != 0)))
    }
}

impl Watcher {
    /// A watcher declaring jobs on `cw`.
    pub fn new(cw: &Client, options: Options) -> Watcher {
        Watcher {
            shared: Arc::new(Shared {
                cw: cw.clone(),
                watch: Watch::new(cw, TAG, options.app.as_deref(), SCHEDULER),
                options,
                entries: Mutex::new(Vec::new()),
            }),
        }
    }

    /// The bridge watch the jobs are declared through.
    pub fn watch(&self) -> &Watch {
        &self.shared.watch
    }

    /// Declares the job `name` with `expr` in `zone` (an IANA name, `""` for
    /// the process's own) and `options`, and gives the backend for its
    /// worker (`WorkerBuilder::new(name).backend(...)`), which ticks on
    /// exactly the fire times CronWatch expects. A name, schedule, or option
    /// CronWatch refuses is an error, with the SDK's message.
    pub fn cron(
        &self,
        name: &str,
        expr: &str,
        zone: &str,
        options: JobOptions,
    ) -> Result<CronScheduler<Schedule>, cronwatch::Error> {
        let schedule = schedule(expr, zone)?;
        self.add(Entry {
            name: name.into(),
            label: format!("apalis-cron worker {}", quote(name)),
            schedule: expr.into(),
            timezone: zone.into(),
            options,
            ..Entry::default()
        })?;
        Ok(CronScheduler::new(schedule))
    }

    /// Declares an entry, with every one declared before it.
    fn add(&self, mut entry: Entry) -> Result<(), cronwatch::Error> {
        entry.defaults = self.shared.options.defaults.clone();
        bridge::validate(&entry.name, &entry.defaults.clone().merge(entry.options.clone()))?;
        let mut entries = lock(&self.shared.entries);
        entries.push(entry);
        self.shared.watch.declare(&entries);
        Ok(())
    }

    /// The layer that records each attempt of a worker's tasks as a run of
    /// the job named after the worker (see the crate's documentation). Add
    /// it after `.retry(...)`, so each attempt is a run of its own.
    pub fn layer(&self) -> WatchLayer {
        WatchLayer { watcher: self.clone(), name: None }
    }

    /// [`layer`](Self::layer), recording the runs under `name` rather than
    /// the worker's name.
    pub fn layer_for(&self, name: &str) -> WatchLayer {
        WatchLayer { watcher: self.clone(), name: Some(name.to_string()) }
    }

    /// The job an attempt of a task of the worker `name` is a run of, or
    /// `None` when it cannot be declared (reported; the attempt then runs
    /// unrecorded, and the next one asks again).
    async fn job_for(&self, name: &str) -> Option<cronwatch::Job> {
        if name == CHECK_WORKER {
            return None;
        }
        if let Some(job) = self.shared.watch.job(name) {
            return Some(job);
        }
        let options = &self.shared.options;
        let own = options.jobs.get(name).cloned().unwrap_or_default();
        self.shared.watch.fallback(name, options.defaults.clone().merge(own)).await
    }

    /// Declares the jobs of the workers made here again, and again without
    /// its schedule each job of this app's the store holds with a schedule
    /// that none of them has (taken out since a process declared it). The
    /// check worker runs it before each check. Everything is written to the
    /// store before it returns.
    pub async fn sync(&self) -> Result<(), cronwatch::Error> {
        {
            let entries = lock(&self.shared.entries);
            self.shared.watch.declare(&entries);
        }
        self.shared.watch.settle().await;
        self.shared.watch.unschedule().await.map(|_| ())
    }

    /// A worker, named [`CHECK_WORKER`], that runs [`sync`](Self::sync)
    /// and a CronWatch check every `every` (a minute is a good interval),
    /// for a service that does not call `Client::start_checking`. Run it beside the
    /// others (`worker.run()`, or a `Monitor`). Its runs are never a job; a
    /// failure is reported to the client's error handler.
    pub fn check_worker(
        &self,
        every: Duration,
    ) -> Result<Worker<Tick, CronScheduler<Schedule>, CheckService, Identity>, cronwatch::Error> {
        let schedule = schedule(&bridge::every_text(every), "")?;
        Ok(WorkerBuilder::new(CHECK_WORKER)
            .backend(CronScheduler::new(schedule))
            .build(CheckService { watcher: self.clone() }))
    }

    /// Waits until what the watcher declared has been written to the store,
    /// for tests and a clean exit.
    pub async fn wait(&self) {
        self.shared.watch.settle().await;
    }
}

#[cfg(feature = "cron")]
mod cron_crate;

/// `name` as JSON writes it, for messages.
fn quote(name: &str) -> String {
    cronwatch::js::stringify(&cronwatch::js::Value::from(name))
}

/// The layer [`Watcher::layer`] gives.
#[derive(Clone)]
pub struct WatchLayer {
    watcher: Watcher,
    name: Option<String>,
}

impl fmt::Debug for WatchLayer {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("WatchLayer").field("name", &self.name).finish_non_exhaustive()
    }
}

impl<S> tower_layer::Layer<S> for WatchLayer {
    type Service = WatchService<S>;

    fn layer(&self, inner: S) -> WatchService<S> {
        WatchService { inner, watcher: self.watcher.clone(), name: self.name.clone() }
    }
}

/// The service [`WatchLayer`] wraps a worker's service in.
#[derive(Clone)]
pub struct WatchService<S> {
    inner: S,
    watcher: Watcher,
    name: Option<String>,
}

impl<S> fmt::Debug for WatchService<S> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("WatchService").field("name", &self.name).finish_non_exhaustive()
    }
}

impl<S, Args> tower_service::Service<Task<Args>> for WatchService<S>
where
    S: tower_service::Service<Task<Args>> + Clone + Send + 'static,
    S::Future: Send + 'static,
    S::Response: Send + 'static,
    S::Error: fmt::Display + Send + 'static,
    Args: Send + 'static,
{
    type Response = S::Response;
    type Error = S::Error;
    type Future = Pin<Box<dyn Future<Output = Result<S::Response, S::Error>> + Send>>;

    fn poll_ready(&mut self, cx: &mut Context<'_>) -> Poll<Result<(), S::Error>> {
        self.inner.poll_ready(cx)
    }

    fn call(&mut self, task: Task<Args>) -> Self::Future {
        // The service polled ready is the one called; a clone takes its
        // place for the next call.
        let clone = self.inner.clone();
        let mut inner = std::mem::replace(&mut self.inner, clone);
        let watcher = self.watcher.clone();
        let name = self.name.clone().or_else(|| task.data().get::<WorkerContext>().map(|w| w.name().to_string()));
        Box::pin(async move {
            let job = match &name {
                Some(name) => watcher.job_for(name).await,
                None => None,
            };
            match job {
                None => inner.call(task).await,
                Some(job) => {
                    job.run_or_discard(RunOptions::new().trigger(TRIGGER), given_back::<S::Error>, move |_| {
                        inner.call(task)
                    })
                    .await
                }
            }
        })
    }
}

/// Whether an attempt ended without failing and without doing its work:
/// deferred (`DeferredError` or `RetryAfterError`, the task put back as
/// pending, as River's snooze is given back in the Go port), or cancelled
/// while it ran (apalis's `AbortError` around its lifecycle's `Exit`).
fn given_back<E: 'static>(err: &E) -> bool {
    let any = err as &dyn Any;
    if any.is::<DeferredError>() || any.is::<RetryAfterError>() {
        return true;
    }
    let Some(boxed) = any.downcast_ref::<BoxDynError>() else {
        return false;
    };
    if boxed.is::<DeferredError>() || boxed.is::<RetryAfterError>() {
        return true;
    }
    boxed.downcast_ref::<AbortError>().is_some_and(|abort| {
        std::error::Error::source(abort)
            .and_then(|source| source.downcast_ref::<TaskLifecycleError>())
            .is_some_and(|e| matches!(e, TaskLifecycleError::Exit(_)))
    })
}

/// The service of [`Watcher::check_worker`].
#[derive(Clone)]
pub struct CheckService {
    watcher: Watcher,
}

impl fmt::Debug for CheckService {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CheckService").finish_non_exhaustive()
    }
}

impl<Args> tower_service::Service<Task<Args>> for CheckService {
    type Response = ();
    type Error = BoxDynError;
    type Future = Pin<Box<dyn Future<Output = Result<(), BoxDynError>> + Send>>;

    fn poll_ready(&mut self, _: &mut Context<'_>) -> Poll<Result<(), BoxDynError>> {
        Poll::Ready(Ok(()))
    }

    fn call(&mut self, _: Task<Args>) -> Self::Future {
        let watcher = self.watcher.clone();
        Box::pin(async move {
            let cw = &watcher.shared.cw;
            match tokio::time::timeout(SYNC_TIMEOUT, watcher.sync()).await {
                Ok(Ok(())) => {}
                Ok(Err(err)) => cw.report_error(err, "apalis"),
                Err(_) => cw.report_error(
                    cronwatch::Error::Other(format!(
                        "the sync took longer than {} seconds; gave up",
                        SYNC_TIMEOUT.as_secs()
                    )),
                    "apalis",
                ),
            }
            cw.check().await.map(|_| ()).map_err(|e| Box::new(e) as BoxDynError)
        })
    }
}

#[cfg(test)]
mod tests;

// The README's examples, compiled as doc tests.
#[cfg(doctest)]
#[doc = include_str!("../README.md")]
struct Readme;
