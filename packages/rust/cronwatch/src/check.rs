//! Checks, reads, and the interval (client.ts `check()`, `jobs()`,
//! `silence()`, `start()`).

use std::sync::atomic::Ordering;
use std::time::Duration;

use tokio::sync::watch;

use crate::client::{Client, clamp_limit, lock};
use crate::error::Error;
use crate::evaluate::{
    BASELINE_WINDOW, Evaluation, apply_silence, empty_state, is_stuck, normalize_state, on_check, release_sending,
    silence_end, summarize, unevaluable_summary,
};
use crate::options::DurationSpec;
use crate::panics::panic_text;
use crate::run::timeout_text;
use crate::schedule;
use crate::types::{Alert, CheckResult, JobState, JobSummary, Run, RunStatus, StoredJob, run_duration};

/// How often a check prunes old runs.
const PRUNE_INTERVAL: i64 = 60 * 60_000;
/// How long `start_checking` waits before its first check.
const FIRST_CHECK_DELAY: Duration = Duration::from_secs(1);
/// The longest interval `start_checking` checks on, the SDK's: setInterval's longest
/// delay, 2^31 - 1 ms (some 24.8 days).
const TIMER_MAX_MS: u64 = (1 << 31) - 1;

/// A check's outcome, shared by every caller waiting on it.
pub(crate) type CheckResultShared = Result<CheckResult, Error>;

/// A job's summary and its newest runs.
#[derive(Clone, Debug, PartialEq)]
#[non_exhaustive]
pub struct JobWithRuns {
    pub job: JobSummary,
    pub runs: Vec<Run>,
}

impl Client {
    /// Looks for missed and stuck runs across every job, sends alerts, retries
    /// alerts no channel accepted, and prunes old runs. Call it from an
    /// interval ([`start_checking`](Self::start_checking)), a cron, or by hand. Concurrent calls
    /// share one check. A job that cannot be evaluated is reported to the
    /// error handler and shown as failing; the error returned is for the
    /// store failing as the check starts.
    ///
    /// The shared check runs in a task of its own, so a caller whose future
    /// is dropped neither fails the check for the others nor leaves a job
    /// half checked. A panic in the check (a store's, say) is that check's
    /// error, and the next call runs a new one.
    pub async fn check(&self) -> Result<CheckResult, Error> {
        let mut rx = {
            let mut checking = lock(&self.inner.checking);
            match checking.as_ref() {
                Some(rx) => rx.clone(),
                None => {
                    let (tx, rx) = watch::channel(None);
                    *checking = Some(rx.clone());
                    let client = self.clone();
                    self.inner.handle.spawn(async move {
                        let inner = client.clone();
                        let result = match client.inner.handle.spawn(async move { inner.run_check().await }).await {
                            Ok(result) => result,
                            Err(join) => {
                                let text =
                                    if join.is_panic() { panic_text(&*join.into_panic()) } else { "cancelled".into() };
                                Err(Error::Other(format!("the check panicked: {text}")))
                            }
                        };
                        *lock(&client.inner.checking) = None;
                        let _ = tx.send(Some(result));
                    });
                    rx
                }
            }
        };
        let result = rx.wait_for(Option::is_some).await.map(|v| v.clone());
        match result {
            Ok(Some(result)) => result,
            _ => Err(Error::Other("the check ended before it could be read".into())),
        }
    }

    async fn run_check(&self) -> Result<CheckResult, Error> {
        self.ensure_ready().await?;
        let mut alerts = Vec::new();
        for source in &self.inner.sources {
            match source.sync(self).await {
                Ok(found) => alerts.extend(found),
                Err(err) => self.report(Error::Other(err.to_string()), &format!("source {}", source.name())),
            }
        }
        for def in self.declared_all() {
            self.sync(&def).await?;
        }
        let now = self.now();
        let store = &self.inner.store;

        // Runs that never reported back. One that cannot be judged (its job's
        // stored timeout no longer parses, say) is reported and skipped.
        for listed in store.running_runs().await.map_err(Error::store)? {
            if let Err(err) = self.check_running(&listed, now, &mut alerts).await {
                self.report(err, &format!("checking {}", listed.job));
            }
        }

        // Each job on its own: one that cannot be evaluated is reported, shown
        // as failing (see `unevaluable_summary`), and does not stop the others.
        let mut jobs = Vec::new();
        let mut spent = Duration::ZERO;
        for job in self.stored_jobs().await? {
            match self.check_job(&job, now, &mut spent).await {
                Ok((summary, found)) => {
                    alerts.extend(found);
                    jobs.push(summary);
                }
                Err(err) => {
                    self.report(err, &format!("checking {}", job.name));
                    jobs.push(self.unevaluable(&job, now).await);
                }
            }
        }

        let mut pruned = 0;
        if now - self.inner.last_prune_at.load(Ordering::Relaxed) > PRUNE_INTERVAL {
            self.inner.last_prune_at.store(now, Ordering::Relaxed);
            match store.prune(now - self.inner.retention_ms as i64).await {
                Ok(n) => pruned = n as i64,
                Err(err) => self.report(Error::store(err), "pruning"),
            }
        }
        Ok(CheckResult { checked_at: now, jobs, alerts, pruned })
    }

    /// A running run marked timed out once it has gone on past its job's
    /// timeout, and judged. The listed run only says whether it is past its
    /// timeout; the row marked is read again just before the write, so lines
    /// and metrics flushed since the list was read (while earlier stuck runs
    /// were sent, say) are kept.
    async fn check_running(&self, listed: &Run, now: i64, alerts: &mut Vec<Alert>) -> Result<(), Error> {
        let def = match self.declared(&listed.job) {
            Some(declared) => declared.stored.clone(),
            None => match self.inner.store.get_job(&listed.job).await.map_err(Error::store)? {
                Some(stored) => {
                    evaluable(&stored)?;
                    stored.read_leniently().definition
                }
                None => return Ok(()),
            },
        };
        if !is_stuck(&def, listed, now).map_err(Error::Other)? {
            return Ok(());
        }
        let Some(mut run) = self.inner.store.get_run(&listed.id).await.map_err(Error::store)? else {
            return Ok(());
        };
        if run.status != RunStatus::Running || run.job != listed.job {
            return Ok(());
        }
        run.status = RunStatus::Timeout;
        run.finished_at = Some(now);
        run.duration_ms = Some(run_duration(run.started_at, now));
        run.error = Some(format!("Still running after {}; marked as timed out", timeout_text(&def)));
        // Only over a row still running: a finish that landed meanwhile wins.
        if self.write_run_if(&run, &[RunStatus::Running]).await? {
            alerts.extend(self.finish_run(&def, &run, now).await);
        }
        Ok(())
    }

    /// One job's part of a check: missed, then retries and sends.
    async fn check_job(
        &self,
        job: &StoredJob,
        now: i64,
        spent: &mut Duration,
    ) -> Result<(JobSummary, Vec<Alert>), Error> {
        evaluable(job)?;
        let recent = self.inner.store.list_runs(&job.name, BASELINE_WINDOW).await.map_err(Error::store)?;
        let last = recent.first();
        let (state, ((held, dropped), next_expected_at)) = self
            .update_state(&job.name, async { Ok(()) }, |previous, _| {
                let out = on_check(&job.definition, job, last, &previous, now).map_err(Error::Other)?;
                let settled = apply_silence(&previous, out.evaluation, now);
                // Alerts a process stopped sending part way go back to the
                // retry queue.
                let (released, let_go) = release_sending(&settled.state, self.now());
                let (state, (alerts, dropped)) =
                    self.outbox(Evaluation { state: released, alerts: settled.alerts }, &job.definition, now);
                Ok((state, ((alerts, let_go + dropped), out.next_expected_at)))
            })
            .await?;
        self.report_dropped(&job.name, dropped);
        let mut alerts = self.retry_undelivered(&job.name, &state, now, spent).await;
        alerts.extend(self.dispatch(&job.name, held, now).await);
        let summary = summarize(job, &recent, &state, next_expected_at, now).map_err(Error::Other)?;
        Ok((summary, alerts))
    }

    /// A job's summary and its newest runs, without alerting. A job that
    /// cannot be evaluated is reported and shown as failing.
    async fn snapshot(&self, job: &StoredJob, now: i64, runs: usize) -> JobWithRuns {
        let read = async {
            let recent =
                self.inner.store.list_runs(&job.name, runs.max(BASELINE_WINDOW)).await.map_err(Error::store)?;
            evaluable(job)?;
            let state = self.read_state(&job.name).await?;
            let out = on_check(&job.definition, job, recent.first(), &state, now).map_err(Error::Other)?;
            let summary = summarize(job, &recent, &state, out.next_expected_at, now).map_err(Error::Other)?;
            Ok::<_, Error>((summary, recent))
        };
        match read.await {
            Ok((summary, mut recent)) => {
                recent.truncate(runs);
                JobWithRuns { job: summary, runs: recent }
            }
            Err(err) => {
                self.report(err, &format!("reading {}", job.name));
                let mut recent = self.inner.store.list_runs(&job.name, runs).await.unwrap_or_default();
                recent.truncate(runs);
                JobWithRuns { job: self.unevaluable(job, now).await, runs: recent }
            }
        }
    }

    /// The summary of a job whose evaluation failed, from whatever can still
    /// be read.
    async fn unevaluable(&self, job: &StoredJob, now: i64) -> JobSummary {
        let recent = self.inner.store.list_runs(&job.name, BASELINE_WINDOW).await.unwrap_or_default();
        let state = self.read_state(&job.name).await.unwrap_or_else(|_| empty_state(&job.name));
        unevaluable_summary(job, &recent, &state, now)
    }

    /// Every job the store knows about, with its health. It sends no alerts.
    pub async fn jobs(&self) -> Result<Vec<JobSummary>, Error> {
        Ok(self.jobs_with_runs(0).await?.into_iter().map(|j| j.job).collect())
    }

    /// Every job's summary with its newest `limit` runs (0 to 500), read
    /// together. What the dashboard shows.
    pub async fn jobs_with_runs(&self, limit: usize) -> Result<Vec<JobWithRuns>, Error> {
        self.ensure_ready().await?;
        let jobs = self.stored_jobs().await?;
        let now = self.now();
        let mut out = Vec::new();
        for job in jobs {
            out.push(self.snapshot(&job, now, clamp_limit(limit, 0)).await);
        }
        Ok(out)
    }

    /// One job's summary, or `None` when the store does not know it. One
    /// declared here and forgotten elsewhere is written again, as a check
    /// does.
    pub async fn job_summary(&self, name: &str) -> Result<Option<JobSummary>, Error> {
        self.ensure_ready().await?;
        if let Some(def) = self.declared(name) {
            self.sync_with(&def, true).await?;
        }
        let Some(stored) = self.inner.store.get_job(name).await.map_err(Error::store)? else {
            return Ok(None);
        };
        Ok(Some(self.snapshot(&stored.read_leniently(), self.now(), 0).await.job))
    }

    /// A job's runs, newest first. `limit` is 1 to 500.
    pub async fn runs(&self, name: &str, limit: usize) -> Result<Vec<Run>, Error> {
        self.ensure_ready().await?;
        self.inner.store.list_runs(name, clamp_limit(limit, 1)).await.map_err(Error::store)
    }

    /// One run by its id, or `None`.
    pub async fn get_run(&self, id: &str) -> Result<Option<Run>, Error> {
        self.ensure_ready().await?;
        self.inner.store.get_run(id).await.map_err(Error::store)
    }

    /// Stops alerts for a job for a while. State keeps updating underneath:
    /// nothing opens while it is silenced, so the first problem after the
    /// silence alerts as usual. The end is a whole millisecond, held at
    /// 2^53 - 1.
    pub async fn silence(&self, name: &str, d: impl Into<DurationSpec>) -> Result<JobState, Error> {
        let ms = schedule::parse_duration(&d.into().to_value(), "silence duration").map_err(Error::Invalid)?;
        self.silence_ms(name, ms).await
    }

    /// Silences a job for `ms` milliseconds, a value `parse_duration` read.
    pub(crate) async fn silence_ms(&self, name: &str, ms: f64) -> Result<JobState, Error> {
        let until = silence_end(self.now(), ms);
        self.patch_state(name, move |s| s.silenced_until = Some(until)).await
    }

    /// Ends a silence.
    pub async fn unsilence(&self, name: &str) -> Result<JobState, Error> {
        self.patch_state(name, |s| s.silenced_until = None).await
    }

    /// Reads, changes, and writes one job's state, in turn with every other
    /// update to it.
    async fn patch_state(&self, name: &str, change: impl Fn(&mut JobState)) -> Result<JobState, Error> {
        self.ensure_ready().await?;
        let (state, ()) = self
            .update_state(name, async { Ok(()) }, |current, _| {
                let mut next = normalize_state(Some(&current), name);
                change(&mut next);
                Ok((next, ()))
            })
            .await?;
        Ok(state)
    }

    /// Removes a job and its runs from the store. A job still declared in code
    /// comes back: here on its next run, and in any other process that
    /// declares it on its next run there, or at that process's next check or
    /// dashboard read.
    pub async fn forget(&self, name: &str) -> Result<(), Error> {
        self.ensure_ready().await?;
        {
            let mut declared = lock(&self.inner.declared);
            if declared.definitions.remove(name).is_some() {
                declared.order.retain(|n| n != name);
            }
            declared.synced.remove(name);
        }
        self.inner.store.delete_job(name).await.map_err(Error::store)
    }

    /// Checks on an interval in a task, for long-running services: the first
    /// check a second from now, then every `every` (a minute when zero, five
    /// seconds at least). Not for serverless functions, where nothing runs
    /// between requests: call [`check`](Self::check) from a cron there
    /// instead. A second call does nothing, under either name; [`stop`](Self::stop)
    /// stops it.
    pub fn start_checking(&self, every: Duration) {
        let mut timer = lock(&self.inner.timer);
        if timer.is_some() {
            return;
        }
        // At most the SDK's longest interval (setInterval's), which also
        // keeps tokio's clock from overflowing on `Duration::MAX`.
        let every = if every.is_zero() { Duration::from_secs(60) } else { every }
            .clamp(Duration::from_secs(5), Duration::from_millis(TIMER_MAX_MS));
        if self.inner.defer_delivery && !self.inner.warned_deferred_start.swap(true, Ordering::Relaxed) {
            eprintln!(
                "[cronwatch] start_checking() was called with Deliver::AtCheck, so these checks send no alerts. Another process must run checks with Deliver::Now (the default) to send them."
            );
        }
        let client = self.clone();
        *timer = Some(self.inner.handle.spawn(async move {
            tokio::time::sleep(FIRST_CHECK_DELAY).await;
            let mut ticker =
                tokio::time::interval_at(tokio::time::Instant::now() + every - FIRST_CHECK_DELAY.min(every), every);
            // Each tick asks for a check without waiting on it, as
            // setInterval does: a tick while a long check runs shares that
            // check, and the ticks it outlasted are not run back to back
            // after it.
            loop {
                let client = client.clone();
                client.inner.handle.clone().spawn(async move {
                    if let Err(err) = client.check().await {
                        client.report(err, "check");
                    }
                });
                ticker.tick().await;
            }
        }));
    }

    /// `start_checking`'s old name, which reads like a job's `start` (which
    /// opens a run). Does exactly what `start_checking` does.
    #[deprecated(note = "renamed start_checking, since a job's start opens a run; this name goes in 2.0")]
    pub fn start(&self, every: Duration) {
        self.start_checking(every);
    }

    /// Stops the interval [`start_checking`](Self::start_checking) began. A check in flight
    /// finishes, since it runs in a task of its own.
    pub fn stop(&self) {
        if let Some(timer) = lock(&self.inner.timer).take() {
            timer.abort();
        }
    }
}

/// An error for a job whose stored definition was not a JSON object
/// (`StoredJob::read`): reported, and shown as failing, while the others
/// carry on.
fn evaluable(job: &StoredJob) -> Result<(), Error> {
    if job.is_readable() {
        return Ok(());
    }
    Err(Error::Other(format!("job \"{}\": its stored definition is not a JSON object", job.name)))
}
