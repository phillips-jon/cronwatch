//! Running a job: the recorded run around a function (`execute`), how a
//! finished run is judged (`conclude`), and how its finish is written once,
//! however many processes finish it (`record_finish`, `claim_finish`).

use std::any::{Any, type_name};
use std::fmt;
use std::future::Future;
use std::panic::{AssertUnwindSafe, catch_unwind, resume_unwind};
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::Duration;

use tokio::sync::watch;
use tokio::task::JoinHandle;

use crate::client::{Client, JobDef, new_id};
use crate::error::Error;
use crate::evaluate::{BASELINE_WINDOW, apply_silence, on_run_finish, on_run_start, timeout_ms};
use crate::handle::RunHandle;
use crate::js;
use crate::output::{self, Recorder};
use crate::panics::{panic_text, take_frames};
use crate::schedule::{MAX_INTERVAL_MS, format_duration};
use crate::serialize::check_expectation;
use crate::types::{Alert, Definition, Metrics, Run, RunStatus, run_duration};

/// Runs read for a baseline, and the most read when failures crowd out the
/// successes.
const HISTORY_PAGE: usize = BASELINE_WINDOW + 5;
const HISTORY_MAX: usize = 200;

/// A start with an id still in flight, which a second start of that id in
/// this process waits on.
pub(crate) type StartCall = watch::Receiver<Option<Result<RunHandle, Error>>>;

/// A declared job's handle. Cheap to clone.
#[derive(Clone)]
pub struct Job {
    pub(crate) client: Client,
    pub(crate) def: Arc<JobDef>,
}

impl fmt::Debug for Job {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Job").field("name", &self.def.name).finish_non_exhaustive()
    }
}

/// Options for [`Job::run_with`].
#[derive(Clone, Debug, Default)]
pub struct RunOptions {
    pub(crate) trigger: Option<String>,
}

impl RunOptions {
    /// No options: the trigger is `run`.
    pub fn new() -> Self {
        Self::default()
    }

    /// Names what started the run.
    pub fn trigger(mut self, trigger: impl Into<String>) -> Self {
        self.trigger = Some(trigger.into());
        self
    }
}

/// Options for [`Job::start`].
#[derive(Clone, Debug, Default)]
pub struct StartOptions {
    pub(crate) trigger: Option<String>,
    pub(crate) id: Option<String>,
}

impl StartOptions {
    /// No options: the trigger is `start`, and the run gets a new id.
    pub fn new() -> Self {
        Self::default()
    }

    /// Names what started the run.
    pub fn trigger(mut self, trigger: impl Into<String>) -> Self {
        self.trigger = Some(trigger.into());
        self
    }

    /// Your own stable id for the run, such as a queue's job id: 1 to 200
    /// characters, with no NUL, not starting with `pgcron:` (the pg_cron
    /// source's). A start with an id already recorded for this job records
    /// nothing and returns a handle on that run instead; an id recorded for
    /// another job is an error.
    pub fn id(mut self, id: impl Into<String>) -> Self {
        self.id = Some(id.into());
        self
    }
}

/// Options for [`Client::record_run`].
#[derive(Clone, Copy, Debug, Default)]
pub struct RecordOptions {
    pub(crate) skip_evaluation: bool,
}

impl RecordOptions {
    /// No options: the run is judged.
    pub fn new() -> Self {
        Self::default()
    }

    /// Stores the run without judging it, for history imported on first sight.
    pub fn without_evaluation(mut self) -> Self {
        self.skip_evaluation = true;
        self
    }
}

tokio::task_local! {
    static CURRENT: JobContext;
}

/// The job context of the run the calling task belongs to, or `None` outside
/// one, so code deep in a call chain can log to its run.
pub fn current() -> Option<JobContext> {
    CURRENT.try_with(Clone::clone).ok()
}

/// What a job's function gets: its run, where it logs output and reports
/// metrics, and when its timeout passes. Cheap to clone.
#[derive(Clone)]
pub struct JobContext {
    inner: Arc<ContextInner>,
}

struct ContextInner {
    name: String,
    run_id: String,
    started_at: i64,
    rec: Arc<Recorder>,
    cancelled: watch::Receiver<bool>,
}

impl fmt::Debug for JobContext {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("JobContext").field("name", &self.inner.name).field("run_id", &self.inner.run_id).finish()
    }
}

impl JobContext {
    /// The job's name.
    pub fn name(&self) -> &str {
        &self.inner.name
    }

    /// The run's id.
    pub fn run_id(&self) -> &str {
        &self.inner.run_id
    }

    /// When the run started, in epoch milliseconds.
    pub fn started_at(&self) -> i64 {
        self.inner.started_at
    }

    /// Appends a line of output, written with its `Display`. Kept with the
    /// run (the last 16 KB), shown in alerts and on the dashboard.
    pub fn log(&self, line: impl fmt::Display) {
        self.inner.rec.log(line.to_string());
    }

    /// Reports a number for this run: tokens, cost, rows, anything. Watched
    /// against budgets and baselines. A later value for the same name
    /// replaces an earlier one. A number that is not finite is refused.
    pub fn metric(&self, name: &str, value: f64) -> Result<(), Error> {
        self.inner.rec.metric(name, value).map_err(Error::Invalid)
    }

    /// Reports several numbers at once.
    pub fn metrics(&self, values: &Metrics) -> Result<(), Error> {
        for (name, value) in values.iter() {
            self.metric(name, value)?;
        }
        Ok(())
    }

    /// Resolves when the job's timeout passes, the SDK's `signal`: the
    /// function decides what to do, as a JavaScript function decides what to
    /// do with an aborted signal. It never resolves for a run that ends in
    /// time.
    pub async fn cancelled(&self) {
        let mut rx = self.inner.cancelled.clone();
        if rx.wait_for(|c| *c).await.is_err() {
            std::future::pending::<()>().await;
        }
    }

    /// Whether the job's timeout has passed.
    pub fn is_cancelled(&self) -> bool {
        *self.inner.cancelled.borrow()
    }
}

/// A future that catches a panic in the future it polls, as
/// `std::panic::catch_unwind` does for a closure.
pub(crate) struct CatchUnwind<F: Future>(pub(crate) Pin<Box<F>>);

impl<F: Future> Future for CatchUnwind<F> {
    type Output = Result<F::Output, Box<dyn Any + Send>>;

    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        match catch_unwind(AssertUnwindSafe(|| self.0.as_mut().poll(cx))) {
            Ok(Poll::Ready(v)) => Poll::Ready(Ok(v)),
            Ok(Poll::Pending) => Poll::Pending,
            Err(panic) => Poll::Ready(Err(panic)),
        }
    }
}

/// A value's text when it is a `String` or a `&str`: what a job returns
/// becomes its output when nothing was logged, as the SDK keeps a returned
/// string.
pub(crate) fn text_of<T: Any>(value: &T) -> Option<String> {
    let any = value as &dyn Any;
    any.downcast_ref::<String>().cloned().or_else(|| any.downcast_ref::<&str>().map(|s| s.to_string()))
}

/// How a job's function ended.
pub(crate) enum Outcome<T, E> {
    Value(T),
    Error(E),
    Panic(Box<dyn Any + Send>),
}

/// A run once recorded, and how its function ended.
pub(crate) struct Executed<T, E> {
    pub(crate) run: Run,
    pub(crate) outcome: Outcome<T, E>,
}

/// The error a value a job returned fails its run with: an HTTP answer of
/// 400 or more (`HTTP 503 Service Unavailable`), as the SDK fails a run for
/// a fetch `Response`. Any other value fails nothing.
pub(crate) fn http_failure<T: Any>(value: &T) -> Option<String> {
    crate::web::status_of(value as &dyn Any).and_then(crate::web::http_failure_text)
}

/// An error as a failed run's error: `Name: message`, the name from the
/// error's type (see `output::error_name`), not capped: it is redacted and
/// then capped with the run's output (`redact_and_cap`).
pub(crate) fn error_text<E: fmt::Display + ?Sized>(err: &E) -> String {
    // An error whose Display panics must not leave its run running.
    let message = catch_unwind(AssertUnwindSafe(|| err.to_string()))
        .unwrap_or_else(|panic| format!("its Display panicked: {}", panic_text(&*panic)));
    output::describe(output::error_name(type_name::<E>()), &message, &[])
}

/// A panic as a failed run's error: `panic: <message>`, with the frames the
/// opt-in hook kept (`capture_panic_frames`), not capped, as `error_text`.
fn panic_error(panic: &(dyn Any + Send)) -> String {
    output::describe("panic", &panic_text(panic), &take_frames())
}

/// `ms` milliseconds as a `Duration`, held at 2^53 ms past it, so a timeout
/// of any length is one tokio can wait for.
pub(crate) fn ms_duration(ms: f64) -> Duration {
    Duration::from_secs_f64((ms.clamp(0.0, MAX_INTERVAL_MS as f64)) / 1000.0)
}

/// How a run's start went: whether its row was written, and the task
/// closing missed and stuck beside the job.
type Started = (bool, Option<JoinHandle<()>>);

/// Records a run as failed if the future running it is dropped while the
/// job's function runs, rather than leave it `running` to be reported stuck
/// at its timeout.
struct DropGuard {
    client: Client,
    def: Arc<JobDef>,
    run: Run,
    rec: Arc<Recorder>,
    start: Option<JoinHandle<Started>>,
    started: Option<Started>,
    armed: bool,
    /// Whether the start closed missed and stuck; a run that may be given
    /// back leaves that to its end, which a dropped run has reached.
    closed_on_start: bool,
}

/// A task aborted when this is dropped: the job's timeout timer, which
/// would otherwise outlive a run whose future was dropped.
struct AbortOnDrop(JoinHandle<()>);

impl Drop for AbortOnDrop {
    fn drop(&mut self) {
        self.0.abort();
    }
}

impl DropGuard {
    async fn wait_start(&mut self) -> bool {
        if let Some(start) = self.start.as_mut() {
            let started = start.await.unwrap_or((false, None));
            self.start = None;
            self.started = Some(started);
        }
        self.started.as_ref().is_some_and(|s| s.0)
    }
}

impl Drop for DropGuard {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        let client = self.client.clone();
        let def = self.def.clone();
        let run = self.run.clone();
        let rec = self.rec.clone();
        let start = self.start.take();
        let started = self.started.take();
        let closed_on_start = self.closed_on_start;
        self.client.inner.handle.spawn(async move {
            let (recorded, closing) = match (start, started) {
                (Some(start), _) => start.await.unwrap_or((false, None)),
                (None, Some(started)) => started,
                (None, None) => (false, None),
            };
            let closing = match closing {
                None if recorded && !closed_on_start => Some(client.close_on_start(&def.name)),
                closing => closing,
            };
            let failure = "Cancelled: the run's future was dropped before it finished".to_string();
            client.finish_executed(&def, run, &rec, None, Some(failure), recorded, closing).await;
        });
    }
}

impl Job {
    /// The job's name.
    pub fn name(&self) -> &str {
        &self.def.name
    }

    /// The job's definition as it is stored.
    pub fn definition(&self) -> &Definition {
        &self.def.stored
    }

    /// The client the job was declared on.
    pub fn client(&self) -> &Client {
        &self.client
    }

    /// Runs `f` now as a recorded run and returns what it returns. The run is
    /// recorded however the store is doing: store errors go to the error
    /// handler, never to the caller. An `Err` fails the run. A `String` or
    /// `&str` returned is the run's output when nothing was logged (and what
    /// an expect rule checks). A panic in `f` is recorded as a failed run and
    /// then resumed. Dropping the returned future while `f` runs records the
    /// run as failed; dropping it after `f` returned leaves the recording to
    /// finish in a task of its own. The returned future is `Send` when `f`'s
    /// future, `T` and `E` are, so it can be spawned.
    pub async fn run<F, Fut, T, E>(&self, f: F) -> Result<T, E>
    where
        F: FnOnce(JobContext) -> Fut,
        Fut: Future<Output = Result<T, E>>,
        T: 'static,
        E: fmt::Display,
    {
        self.run_with(RunOptions::new(), f).await
    }

    /// [`run`](Self::run) with options.
    pub async fn run_with<F, Fut, T, E>(&self, options: RunOptions, f: F) -> Result<T, E>
    where
        F: FnOnce(JobContext) -> Fut,
        Fut: Future<Output = Result<T, E>>,
        T: 'static,
        E: fmt::Display,
    {
        let trigger = options.trigger.unwrap_or_else(|| "run".into());
        self.client.execute(self.def.clone(), trigger, None::<fn(&E) -> bool>, f).await
    }

    /// [`run_with`](Self::run_with), taking the run back rather than judging
    /// it when `f` returns an error `discard_when` answers true for: an
    /// attempt a queue gives back without failing, such as an apalis task
    /// deferred with `DeferredError`. The running row is deleted (through
    /// [`Store::delete_run_if`](crate::Store::delete_run_if)), nothing is
    /// judged or alerted, the job's state is left as it was (the attempt
    /// closes neither missed nor stuck), and the error is still returned. A
    /// row a check already marked stuck is left as it is, and a store
    /// without `delete_run_if` records the run as it ended; both are
    /// reported to the error handler as `discarding <job>`, as is a
    /// `discard_when` that panics, whose run is then recorded. A panic in `f`
    /// is never taken back. The SDK has no counterpart; the Go port's
    /// `DiscardWhen` and the PHP port's released Laravel job follow the same
    /// rule.
    pub async fn run_or_discard<F, Fut, T, E, D>(&self, options: RunOptions, discard_when: D, f: F) -> Result<T, E>
    where
        F: FnOnce(JobContext) -> Fut,
        Fut: Future<Output = Result<T, E>>,
        T: 'static,
        E: fmt::Display,
        D: Fn(&E) -> bool,
    {
        let trigger = options.trigger.unwrap_or_else(|| "run".into());
        self.client.execute(self.def.clone(), trigger, Some(discard_when), f).await
    }
}

impl Client {
    /// Runs a job by name without keeping a handle, declaring it on first use
    /// (or again, when `options` is given).
    pub async fn run<F, Fut, T, E>(
        &self,
        name: &str,
        options: Option<crate::JobOptions>,
        f: F,
    ) -> Result<Result<T, E>, Error>
    where
        F: FnOnce(JobContext) -> Fut,
        Fut: Future<Output = Result<T, E>>,
        T: 'static,
        E: fmt::Display,
    {
        let def = match (options, self.declared(name)) {
            (None, Some(def)) => def,
            (options, _) => self.job(name, options.unwrap_or_default())?.def,
        };
        Ok(self.execute(def, "run".into(), None::<fn(&E) -> bool>, f).await)
    }

    /// Runs `f` as a recorded run. The function always runs, whatever the
    /// store is doing: store errors go to the error handler, and the result
    /// is the function's own outcome. `discard`, when given, says which
    /// returned errors take the run back rather than finish it
    /// (`Job::run_or_discard`).
    async fn execute<F, Fut, T, E, D>(
        &self,
        def: Arc<JobDef>,
        trigger: String,
        discard: Option<D>,
        f: F,
    ) -> Result<T, E>
    where
        F: FnOnce(JobContext) -> Fut,
        Fut: Future<Output = Result<T, E>>,
        T: 'static,
        E: fmt::Display,
        D: Fn(&E) -> bool,
    {
        match self.execute_run(def, trigger, discard, f, http_failure::<T>).await.outcome {
            Outcome::Value(v) => Ok(v),
            Outcome::Error(err) => Err(err),
            Outcome::Panic(panic) => resume_unwind(panic),
        }
    }

    /// `execute`, answering the finished run and how the function ended
    /// rather than resuming a panic, for the job's handler, which answers
    /// with both. `judge` gives the error a returned value fails the run
    /// with: an HTTP answer of 400 or more, as the SDK fails a run for a
    /// fetch `Response`. `discard`, when given, says which returned errors
    /// take the run back rather than finish it (`Job::run_or_discard`);
    /// the run answered for one taken back is the run as it started.
    pub(crate) async fn execute_run<F, Fut, T, E, D>(
        &self,
        def: Arc<JobDef>,
        trigger: String,
        discard: Option<D>,
        f: F,
        judge: fn(&T) -> Option<String>,
    ) -> Executed<T, E>
    where
        F: FnOnce(JobContext) -> Fut,
        Fut: Future<Output = Result<T, E>>,
        T: 'static,
        E: fmt::Display,
        D: Fn(&E) -> bool,
    {
        let started_at = self.now();
        let run = Run {
            id: new_id(),
            job: def.name.clone(),
            status: RunStatus::Running,
            started_at,
            finished_at: None,
            duration_ms: None,
            error: None,
            output: None,
            metrics: Metrics::new(),
            trigger,
        };
        // The start is written in a task of its own, so a caller that drops
        // this future part way leaves a whole row, which the guard finishes.
        // A run that may be given back closes missed and stuck only once it
        // is known not to be, as the Go and PHP ports do: one taken back
        // must leave the state as it was, or an overdue job would have
        // missed closed by each attempt given back and opened again by the
        // next check, an alert each time.
        let close_on_start = discard.is_none();
        let start = {
            let (client, def, run) = (self.clone(), def.clone(), run.clone());
            self.inner.handle.spawn(async move { client.begin_run(&def, &run, close_on_start).await })
        };
        let rec = Arc::new(Recorder::new());
        let mut guard = DropGuard {
            client: self.clone(),
            def: def.clone(),
            run: run.clone(),
            rec: rec.clone(),
            start: Some(start),
            started: None,
            armed: true,
            closed_on_start: close_on_start,
        };
        guard.wait_start().await;

        let timeout = timeout_ms(&def.stored).unwrap_or(crate::evaluate::DEFAULT_TIMEOUT_MS);
        let (cancel, cancelled) = watch::channel(false);
        // Aborted when the run ends or its future is dropped.
        let timer = AbortOnDrop(self.inner.handle.spawn(async move {
            tokio::time::sleep(ms_duration(timeout)).await;
            let _ = cancel.send(true);
            // Held until the run ends, so `cancelled` sees the value, not a
            // closed channel.
            std::future::pending::<()>().await;
        }));
        let jc = JobContext {
            inner: Arc::new(ContextInner {
                name: def.name.clone(),
                run_id: run.id.clone(),
                started_at,
                rec: rec.clone(),
                cancelled,
            }),
        };
        // A function that panics before it returns its future panics here,
        // not while it is polled; both are the run's panic. `f` is called
        // before any await, so its own type need not be `Send`.
        let outcome = match catch_unwind(AssertUnwindSafe(|| CURRENT.sync_scope(jc.clone(), || f(jc.clone())))) {
            Ok(fut) => CatchUnwind(Box::pin(CURRENT.scope(jc, fut))).await,
            Err(panic) => Err(panic),
        };
        drop(timer);
        guard.armed = false;
        let (recorded, closing) = guard.started.take().unwrap_or((false, None));

        let (outcome, failure, result_text) = match outcome {
            Err(panic) => {
                let text = panic_error(&*panic);
                (Outcome::Panic(panic), Some(text), None)
            }
            Ok(Err(err)) => {
                let text = error_text(&err);
                if let Some(discard) = &discard {
                    if self.given_back(&def.name, discard, &err) {
                        // Taking the run back and, when that fails, finishing
                        // it are one task, so a caller that drops this future
                        // meanwhile never leaves the run running.
                        let client = self.clone();
                        let task = self.inner.handle.spawn(async move {
                            if !recorded || client.discard_run(&run).await {
                                return None;
                            }
                            let closing = Some(client.close_on_start(&def.name));
                            Some(client.finish_executed(&def, run, &rec, None, Some(text), recorded, closing).await)
                        });
                        let run = match task.await {
                            Ok(run) => run,
                            Err(panic) => {
                                self.report_panicked(panic, &format!("discarding {}", guard.def.name));
                                None
                            }
                        };
                        return Executed {
                            run: run.unwrap_or_else(|| guard.run.clone()),
                            outcome: Outcome::Error(err),
                        };
                    }
                }
                (Outcome::Error(err), Some(text), None)
            }
            Ok(Ok(v)) => {
                let text = text_of(&v);
                let failure = judge(&v);
                (Outcome::Value(v), failure, text)
            }
        };
        let closing = match closing {
            None if recorded && !close_on_start => Some(self.close_on_start(&def.name)),
            closing => closing,
        };
        let client = self.clone();
        let task = self.inner.handle.spawn(async move {
            client.finish_executed(&def, run, &rec, result_text, failure, recorded, closing).await
        });
        // Dropping this future now detaches the recording rather than
        // cancelling it.
        let run = match task.await {
            Ok(run) => run,
            // The recording panicked (a store's, say): reported, and the run
            // as it stood.
            Err(panic) => {
                self.report_panicked(panic, &format!("recording {}", guard.def.name));
                guard.run.clone()
            }
        };
        Executed { run, outcome }
    }

    /// Reports a task of the client's own that panicked (a store's panic, a
    /// channel's), which would otherwise go unseen.
    pub(crate) fn report_panicked(&self, err: tokio::task::JoinError, where_: &str) {
        if let Ok(panic) = err.try_into_panic() {
            self.report(Error::Other(format!("panicked: {}", panic_text(&*panic))), where_);
        }
    }

    /// `discard(err)`, with a panic in it reported and the run not given
    /// back, so it is recorded rather than left running to be reported
    /// stuck.
    fn given_back<E>(&self, name: &str, discard: &impl Fn(&E) -> bool, err: &E) -> bool {
        match catch_unwind(AssertUnwindSafe(|| discard(err))) {
            Ok(back) => back,
            Err(panic) => {
                self.report(Error::Other(format!("panicked: {}", panic_text(&*panic))), &format!("discarding {name}"));
                false
            }
        }
    }

    /// Takes back a run still running (`Job::run_or_discard`) and says
    /// whether the caller is done with it. A store without `delete_run_if`,
    /// or one that fails, is reported and the run finished as it ended, so
    /// it is not left running to be reported stuck; a row no longer running
    /// (a check marked it stuck meanwhile) is reported and left as it is.
    async fn discard_run(&self, run: &Run) -> bool {
        let where_ = format!("discarding {}", run.job);
        match self.inner.store.delete_run_if(&run.id, &run.job, &RunStatus::Running).await {
            Ok(true) => true,
            Ok(false) => {
                self.report(
                    Error::Other(format!("run {} of {} is no longer running; left as it is", run.id, run.job)),
                    &where_,
                );
                true
            }
            Err(err) if crate::store::is_unsupported(&err) => {
                self.report(
                    Error::Other(
                        "the store cannot take back a run (it does not implement Store::delete_run_if); recorded as it ended"
                            .into(),
                    ),
                    &where_,
                );
                false
            }
            Err(err) => {
                self.report(Error::store(err), &where_);
                false
            }
        }
    }

    /// Closes missed and stuck for a run that has started, beside the job.
    fn close_on_start(&self, name: &str) -> JoinHandle<()> {
        let client = self.clone();
        let name = name.to_string();
        self.inner.handle.spawn(async move {
            if let Err(err) = client.update_state(&name, async { Ok(()) }, |s, _| Ok((on_run_start(&s), ()))).await {
                client.report(err, &format!("starting {name}"));
            }
        })
    }

    /// The start of a run: the definition synced, the row inserted, and
    /// (with `close`) missed and stuck closed beside the job, which never
    /// waits on it.
    async fn begin_run(&self, def: &Arc<JobDef>, run: &Run, close: bool) -> Started {
        let name = &def.name;
        let inserted = match self.sync_with(def, true).await {
            Ok(()) => self.inner.store.insert_run(run).await.map_err(Error::store),
            Err(err) => Err(err),
        };
        if let Err(err) = inserted {
            self.report(err, &format!("recording {name}"));
            return (false, None);
        }
        (true, close.then(|| self.close_on_start(name)))
    }

    /// The end of a run: its fields set from how it went, judged, written
    /// once the start's state update is done, and evaluated.
    #[allow(clippy::too_many_arguments)]
    async fn finish_executed(
        &self,
        def: &Arc<JobDef>,
        mut run: Run,
        rec: &Recorder,
        result_text: Option<String>,
        failure: Option<String>,
        recorded: bool,
        closing: Option<JoinHandle<()>>,
    ) -> Run {
        let name = def.name.clone();
        let finished_at = self.now();
        run.finished_at = Some(finished_at);
        run.duration_ms = Some(run_duration(run.started_at, finished_at));
        run.metrics = Metrics::lenient(&js::Value::Object(rec.metrics()));
        run.output = rec.output();
        if run.output.is_none() && failure.is_none() {
            run.output = result_text.clone();
        }
        let mut expect_text = rec.expect_text();
        if expect_text.is_none() && failure.is_none() {
            expect_text = result_text;
        }
        self.conclude(def, &mut run, failure, expect_text.as_deref());
        if let Some(closing) = closing {
            if let Err(panic) = closing.await {
                self.report_panicked(panic, &format!("starting {name}"));
            }
        }
        match self.record_finish(def, &run, recorded, finished_at).await {
            Err(err) => self.report(err, &format!("recording {name}")),
            Ok(Some(why)) => self
                .report(Error::Other(format!("run {} of {name} {why}; ignored", run.id)), &format!("finishing {name}")),
            Ok(None) => {}
        }
        run
    }

    /// Sets a finished run's status and error from how it ended, then redacts
    /// its output and error and caps them, in that order. `failure` is the
    /// error text of a function that failed.
    pub(crate) fn conclude(&self, def: &JobDef, run: &mut Run, failure: Option<String>, expect_text: Option<&str>) {
        if let Some(failure) = failure {
            run.status = RunStatus::Failed;
            run.error = Some(failure);
        } else if let Some(unmet) = check_expectation(def.expect.as_ref(), expect_text) {
            run.status = RunStatus::Failed;
            run.error = Some(unmet);
        } else {
            run.status = RunStatus::Ok;
        }
        // Redacted after the expect check, so a rule can still match what was
        // logged, and before the cap, so the cut cannot keep half a secret.
        // NULs go last, so not even a custom redact can store one.
        run.output = run.output.take().map(|o| output::redact_and_cap(&o, |t| self.redact(t)));
        run.error = run.error.take().map(|e| output::redact_and_cap(&e, |t| self.redact(t)));
    }

    /// Writes a finished run and evaluates it. `recorded` says whether its
    /// start was written; if not, it is inserted now. Returns why nothing was
    /// recorded (another process finished the run first, say). Returns the
    /// store's error, so a handle can be finished again.
    pub(crate) async fn record_finish(
        &self,
        def: &Arc<JobDef>,
        run: &Run,
        recorded: bool,
        finished_at: i64,
    ) -> Result<Option<String>, Error> {
        if !recorded {
            // The start was never written; the store may be back by now.
            self.sync(def).await?;
            match self.inner.store.insert_run(run).await {
                Ok(()) => {
                    self.finish_run(&def.stored, run, finished_at).await;
                    return Ok(None);
                }
                Err(err) => {
                    // Another process may have recorded a run with this id meanwhile.
                    match self.inner.store.get_run(&run.id).await {
                        Ok(Some(stored)) if stored.job != run.job => {
                            return Ok(Some(format!("belongs to job {}", js::quote(&stored.job))));
                        }
                        Ok(Some(_)) => {}
                        _ => return Err(Error::store(err)),
                    }
                }
            }
        }
        let (late, ignored) = self.claim_finish(run).await?;
        if ignored.is_some() {
            return Ok(ignored);
        }
        if !late || run.status == RunStatus::Ok {
            self.finish_run(&def.stored, run, finished_at).await;
        }
        Ok(None)
    }

    /// A conditional write (`Store::update_run_if`), or for a store without
    /// one, a read then a plain write.
    pub(crate) async fn write_run_if(&self, run: &Run, from: &[RunStatus]) -> Result<bool, Error> {
        let store = &self.inner.store;
        match store.update_run_if(run, from).await {
            Err(err) if crate::store::is_unsupported(&err) => {
                let stored = store.get_run(&run.id).await.map_err(Error::store)?;
                match stored {
                    Some(s) if from.contains(&s.status) => {
                        store.update_run(run).await.map_err(Error::store)?;
                        Ok(true)
                    }
                    _ => Ok(false),
                }
            }
            other => other.map_err(Error::store),
        }
    }

    /// Writes a finished run over its stored row, only while that row is
    /// still running, or else still marked timeout by a check. Only the
    /// process whose write lands goes on to evaluate the run; for the others
    /// it says why nothing was written. `late` means a check already counted
    /// the run as a stuck failure: a late failure must not count twice, while
    /// a late success still closes stuck and recovers.
    pub(crate) async fn claim_finish(&self, run: &Run) -> Result<(bool, Option<String>), Error> {
        if self.write_run_if(run, &[RunStatus::Running]).await? {
            return Ok((false, None));
        }
        if self.write_run_if(run, &[RunStatus::Timeout]).await? {
            return Ok((true, None));
        }
        match self.inner.store.get_run(&run.id).await.map_err(Error::store)? {
            None => Ok((false, Some("was not found".into()))),
            Some(stored) => Ok((false, Some(format!("was already finished as {}", stored.status)))),
        }
    }

    /// Evaluates a finished run (ok, failed, or timed out by a check), already
    /// written, against the job's state, and sends what that produces. The
    /// alerts are written with that state (see `outbox`). Never fails:
    /// problems go to the error handler.
    pub(crate) async fn finish_run(&self, def: &Definition, run: &Run, now: i64) -> Vec<Alert> {
        let result = self
            .update_state(&run.job, self.history(run), |previous, history: &Vec<Run>| {
                let e = on_run_finish(def, run, &previous, history, now).map_err(Error::Other)?;
                Ok(self.outbox(apply_silence(&previous, e, now), def, now))
            })
            .await;
        match result {
            Ok((_, (alerts, dropped))) => {
                self.report_dropped(&run.job, dropped);
                self.dispatch(&run.job, alerts, now).await
            }
            Err(err) => {
                self.report(err, &format!("evaluating {}", run.job));
                Vec::new()
            }
        }
    }

    /// The runs before `run`, newest first, with up to `BASELINE_WINDOW`
    /// successful ones when the store has them. One small read normally; a
    /// larger one only when failures crowd the successes out of it.
    async fn history(&self, run: &Run) -> Result<Vec<Run>, Error> {
        let store = &self.inner.store;
        let mut runs = store.list_runs(&run.job, HISTORY_PAGE).await.map_err(Error::store)?;
        let full = runs.len() == HISTORY_PAGE;
        runs.retain(|r| r.id != run.id);
        if full && runs.iter().filter(|r| r.status == RunStatus::Ok).count() < BASELINE_WINDOW {
            runs = store.list_runs(&run.job, HISTORY_MAX).await.map_err(Error::store)?;
            runs.retain(|r| r.id != run.id);
        }
        Ok(runs)
    }

    /// Records a run that happened outside this process, for a [`Source`](crate::Source).
    /// Its job must be declared with [`job`](Self::job) first. Runs are keyed
    /// by id: a new one is inserted, a stored one still running (or marked
    /// timeout by a check) is finished when this one is not running, and
    /// anything else is left alone, so recording the same run twice changes
    /// nothing. Finishing is conditional: when two processes record the same
    /// finish, only the one whose write lands evaluates it. A stored run of
    /// another job is left alone and reported. A finished run is judged as if
    /// it had been wrapped here (expect, failures, duration, budgets) and its
    /// output and error are redacted the same way. A metric that is not a
    /// finite number is refused before anything is written, as
    /// [`JobContext::metric`] refuses it. Returns the alerts it sent.
    pub async fn record_run(&self, input: Run, options: RecordOptions) -> Result<Vec<Alert>, Error> {
        let Some(def) = self.declared(&input.job) else {
            return Err(Error::Invalid(format!(
                "recordRun: job {} is not declared; call job first",
                js::quote(&input.job)
            )));
        };
        if input.id.contains('\0') {
            return Err(Error::Invalid(format!(
                "recordRun: run ids cannot contain a NUL character (job {})",
                js::quote(&input.job)
            )));
        }
        // Refused as `JobContext::metric` refuses them: a store keeps NaN and
        // infinity as null.
        if let Some((metric, _)) = input.metrics.iter().find(|(_, v)| !v.is_finite()) {
            return Err(Error::Invalid(format!(
                "recordRun: metric {} must be a finite number (job {}, run {})",
                js::quote(metric),
                js::quote(&input.job),
                js::quote(&input.id)
            )));
        }
        self.sync(&def).await?;
        let mut run = input;
        if run.status == RunStatus::Ok {
            if let Some(unmet) = check_expectation(def.expect.as_ref(), run.output.as_deref()) {
                run.status = RunStatus::Failed;
                run.error = Some(unmet);
            }
        }
        run.output = run.output.take().map(|o| output::redact_and_cap(&o, |t| self.redact(t)));
        run.error = run.error.take().map(|e| output::redact_and_cap(&e, |t| self.redact(t)));
        let evaluate = !options.skip_evaluation;
        let store = &self.inner.store;
        if let Some(stored) = store.get_run(&run.id).await.map_err(Error::store)? {
            return self.record_over(&def.stored, &stored, &run, evaluate).await;
        }
        if let Err(err) = store.insert_run(&run).await {
            // Another process recorded it first.
            return match store.get_run(&run.id).await {
                Ok(Some(again)) => self.record_over(&def.stored, &again, &run, evaluate).await,
                _ => Err(Error::store(err)),
            };
        }
        if !evaluate {
            return Ok(Vec::new());
        }
        self.update_state(&run.job, async { Ok(()) }, |s, _| Ok((on_run_start(&s), ()))).await?;
        if run.status == RunStatus::Running {
            return Ok(Vec::new());
        }
        Ok(self.finish_run(&def.stored, &run, self.now()).await)
    }

    /// `record_run` for a run already stored.
    async fn record_over(
        &self,
        def: &Definition,
        stored: &Run,
        run: &Run,
        evaluate: bool,
    ) -> Result<Vec<Alert>, Error> {
        if stored.job != run.job {
            self.report(
                Error::Other(format!(
                    "run {} of {} belongs to job {}; ignored",
                    run.id,
                    run.job,
                    js::quote(&stored.job)
                )),
                &format!("recording {}", run.job),
            );
            return Ok(Vec::new());
        }
        if !matches!(stored.status, RunStatus::Running | RunStatus::Timeout) || run.status == RunStatus::Running {
            return Ok(Vec::new());
        }
        let (late, ignored) = self.claim_finish(run).await?;
        if let Some(why) = ignored {
            self.report(
                Error::Other(format!("run {} of {} {why}; ignored", run.id, run.job)),
                &format!("recording {}", run.job),
            );
            return Ok(Vec::new());
        }
        if !evaluate || (late && run.status != RunStatus::Ok) {
            return Ok(Vec::new());
        }
        Ok(self.finish_run(def, run, self.now()).await)
    }
}

/// A run's timeout as text, for a stuck run's error.
pub(crate) fn timeout_text(def: &Definition) -> String {
    format_duration(timeout_ms(def).unwrap_or(crate::evaluate::DEFAULT_TIMEOUT_MS))
}
