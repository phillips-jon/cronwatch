//! The blocking client, for a `fn main` a crontab runs and for code with no
//! async runtime of its own (diesel, a command-line tool).
//!
//! It owns a single-threaded tokio runtime on a thread of its own, as
//! `reqwest::blocking` does: store calls, alerts and the checks' tasks run
//! there, while a job's function is a plain closure that runs on the calling
//! thread. Every call blocks the calling thread until it is done, so it works
//! anywhere, inside another runtime too; there it blocks one of that
//! runtime's threads, so async code should use [`crate::Client`] instead.
//!
//! ```no_run
//! use cronwatch::JobOptions;
//! use cronwatch::blocking::Client;
//!
//! # fn backup() -> std::io::Result<u64> { Ok(0) }
//! fn main() -> Result<(), Box<dyn std::error::Error>> {
//!     let cw = Client::new(cronwatch::Client::builder())?;
//!     let job = cw.job("nightly-backup", JobOptions::new().schedule("0 3 * * *").timezone("UTC"))?;
//!     job.run(|run| {
//!         let bytes = backup()?;
//!         run.metric("bytes", bytes as f64).ok();
//!         Ok::<_, std::io::Error>(())
//!     })?;
//!     Ok(())
//! }
//! ```

use std::fmt;
use std::future::Future;
use std::pin::pin;
use std::sync::Arc;
use std::task::{Context, Poll, Wake, Waker};
use std::thread::{self, Thread};
use std::time::Duration;

use tokio::runtime::Handle;
use tokio::sync::oneshot;

use crate::store::BoxError;
use crate::{
    Alert, CheckResult, ClientBuilder, DurationSpec, Error, JobContext, JobOptions, JobState, JobSummary, JobWithRuns,
    RecordOptions, Run, RunOptions, StartOptions,
};

struct ThreadWaker(Thread);

impl Wake for ThreadWaker {
    fn wake(self: Arc<Self>) {
        self.0.unpark();
    }
}

/// Polls a future to its end on the calling thread, parking between polls.
/// The work it waits on runs on the client's runtime thread.
fn block_on<F: Future>(fut: F) -> F::Output {
    let waker = Waker::from(Arc::new(ThreadWaker(thread::current())));
    let mut cx = Context::from_waker(&waker);
    let mut fut = pin!(fut);
    loop {
        if let Poll::Ready(v) = fut.as_mut().poll(&mut cx) {
            return v;
        }
        thread::park();
    }
}

/// The runtime thread; it ends when the last client handle is dropped.
struct Runtime {
    handle: Handle,
    stop: Option<oneshot::Sender<()>>,
}

impl Drop for Runtime {
    fn drop(&mut self) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
    }
}

/// The blocking client: [`crate::Client`] with every call made to block.
/// Cheap to clone.
#[derive(Clone)]
pub struct Client {
    inner: crate::Client,
    runtime: Arc<Runtime>,
}

impl fmt::Debug for Client {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("blocking::Client").finish_non_exhaustive()
    }
}

fn start_runtime() -> Result<Runtime, Error> {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| Error::Other(format!("could not start the blocking client's runtime: {e}")))?;
    let handle = rt.handle().clone();
    let (stop, stopped) = oneshot::channel::<()>();
    thread::Builder::new()
        .name("cronwatch".into())
        .spawn(move || {
            rt.block_on(async {
                let _ = stopped.await;
            });
            // A check or a send still in flight gets a moment to finish.
            rt.shutdown_timeout(Duration::from_secs(5));
        })
        .map_err(|e| Error::Other(format!("could not start the blocking client's thread: {e}")))?;
    Ok(Runtime { handle, stop: Some(stop) })
}

impl Client {
    /// Makes a client from the async client's builder, on a runtime thread of
    /// its own.
    pub fn new(builder: ClientBuilder) -> Result<Client, Error> {
        let runtime = start_runtime()?;
        let inner = {
            let _enter = runtime.handle.enter();
            builder.build()?
        };
        Ok(Client { inner, runtime: Arc::new(runtime) })
    }

    /// Makes a client from a builder made on the client's runtime, for a
    /// store that needs one to be made (a sqlx pool, say).
    pub fn with_async<F, Fut>(make: F) -> Result<Client, Error>
    where
        F: FnOnce() -> Fut + Send + 'static,
        Fut: Future<Output = Result<ClientBuilder, BoxError>> + Send + 'static,
    {
        let runtime = start_runtime()?;
        let task = runtime.handle.spawn(async move { make().await.map_err(Error::store)?.build() });
        let inner = block_on(task).map_err(|e| Error::Other(format!("making the client failed: {e}")))??;
        Ok(Client { inner, runtime: Arc::new(runtime) })
    }

    /// Runs a future on the client's runtime and waits for it.
    fn call<T, Fut>(&self, fut: Fut) -> Result<T, Error>
    where
        T: Send + 'static,
        Fut: Future<Output = Result<T, Error>> + Send + 'static,
    {
        match block_on(self.runtime.handle.spawn(fut)) {
            Ok(result) => result,
            Err(join) if join.is_panic() => std::panic::resume_unwind(join.into_panic()),
            Err(join) => Err(Error::Other(format!("the call was cancelled: {join}"))),
        }
    }

    /// The async client this wraps, for what the blocking client does not
    /// carry: the dashboard (`routes`), `defined_jobs`, `store` and the rest,
    /// or async code that shares the client.
    pub fn as_async(&self) -> &crate::Client {
        &self.inner
    }

    /// Declares a job and returns its handle (see [`crate::Client::job`]).
    pub fn job(&self, name: &str, options: JobOptions) -> Result<Job, Error> {
        Ok(Job { job: self.inner.job(name, options)?, client: self.clone() })
    }

    /// See [`crate::Client::check`].
    pub fn check(&self) -> Result<CheckResult, Error> {
        let cw = self.inner.clone();
        self.call(async move { cw.check().await })
    }

    /// See [`crate::Client::jobs`].
    pub fn jobs(&self) -> Result<Vec<JobSummary>, Error> {
        let cw = self.inner.clone();
        self.call(async move { cw.jobs().await })
    }

    /// See [`crate::Client::jobs_with_runs`].
    pub fn jobs_with_runs(&self, limit: usize) -> Result<Vec<JobWithRuns>, Error> {
        let cw = self.inner.clone();
        self.call(async move { cw.jobs_with_runs(limit).await })
    }

    /// See [`crate::Client::job_summary`].
    pub fn job_summary(&self, name: &str) -> Result<Option<JobSummary>, Error> {
        let (cw, name) = (self.inner.clone(), name.to_string());
        self.call(async move { cw.job_summary(&name).await })
    }

    /// See [`crate::Client::runs`].
    pub fn runs(&self, name: &str, limit: usize) -> Result<Vec<Run>, Error> {
        let (cw, name) = (self.inner.clone(), name.to_string());
        self.call(async move { cw.runs(&name, limit).await })
    }

    /// See [`crate::Client::get_run`].
    pub fn get_run(&self, id: &str) -> Result<Option<Run>, Error> {
        let (cw, id) = (self.inner.clone(), id.to_string());
        self.call(async move { cw.get_run(&id).await })
    }

    /// See [`crate::Client::silence`].
    pub fn silence(&self, name: &str, d: impl Into<DurationSpec>) -> Result<JobState, Error> {
        let (cw, name, d) = (self.inner.clone(), name.to_string(), d.into());
        self.call(async move { cw.silence(&name, d).await })
    }

    /// See [`crate::Client::unsilence`].
    pub fn unsilence(&self, name: &str) -> Result<JobState, Error> {
        let (cw, name) = (self.inner.clone(), name.to_string());
        self.call(async move { cw.unsilence(&name).await })
    }

    /// See [`crate::Client::forget`].
    pub fn forget(&self, name: &str) -> Result<(), Error> {
        let (cw, name) = (self.inner.clone(), name.to_string());
        self.call(async move { cw.forget(&name).await })
    }

    /// See [`crate::Client::sync_job`].
    pub fn sync_job(&self, name: &str) -> Result<bool, Error> {
        let (cw, name) = (self.inner.clone(), name.to_string());
        self.call(async move { cw.sync_job(&name).await })
    }

    /// See [`crate::Client::record_run`].
    pub fn record_run(&self, run: Run, options: RecordOptions) -> Result<Vec<Alert>, Error> {
        let cw = self.inner.clone();
        self.call(async move { cw.record_run(run, options).await })
    }

    /// See [`crate::Client::resume_run`].
    pub fn resume_run(&self, name: &str, run_id: &str) -> Result<RunHandle, Error> {
        let (cw, name, run_id) = (self.inner.clone(), name.to_string(), run_id.to_string());
        let handle = self.call(async move { cw.resume_run(&name, &run_id).await })?;
        Ok(RunHandle { handle, client: self.clone() })
    }

    /// Checks on an interval on the client's runtime thread (see
    /// [`crate::Client::start_checking`]).
    pub fn start_checking(&self, every: Duration) {
        self.inner.start_checking(every);
    }

    /// `start_checking`'s old name. Does exactly what `start_checking` does.
    #[deprecated(note = "renamed start_checking, since a job's start opens a run; this name goes in 2.0")]
    pub fn start(&self, every: Duration) {
        self.start_checking(every);
    }

    /// Stops the interval.
    pub fn stop(&self) {
        self.inner.stop();
    }

    /// Stops the interval and closes the store.
    pub fn close(&self) -> Result<(), Error> {
        let cw = self.inner.clone();
        self.call(async move { cw.close().await })
    }
}

/// A declared job's handle on the blocking client.
#[derive(Clone, Debug)]
pub struct Job {
    job: crate::Job,
    client: Client,
}

impl Job {
    /// The job's name.
    pub fn name(&self) -> &str {
        self.job.name()
    }

    /// Runs `f` on the calling thread as a recorded run and returns what it
    /// returns, as [`crate::Job::run`] does: an `Err` fails the run, a
    /// `String` or `&str` returned is the output when nothing was logged, and
    /// a panic is recorded and then resumed. `f` gets the run's context, and
    /// [`crate::current`] finds it too.
    pub fn run<F, T, E>(&self, f: F) -> Result<T, E>
    where
        F: FnOnce(&JobContext) -> Result<T, E>,
        T: 'static,
        E: fmt::Display,
    {
        self.run_with(RunOptions::new(), f)
    }

    /// [`run`](Self::run) with options.
    pub fn run_with<F, T, E>(&self, options: RunOptions, f: F) -> Result<T, E>
    where
        F: FnOnce(&JobContext) -> Result<T, E>,
        T: 'static,
        E: fmt::Display,
    {
        let _enter = self.client.runtime.handle.enter();
        block_on(self.job.run_with(options, |jc| async move { f(&jc) }))
    }

    /// Records a running run now, to finish later (see [`crate::Job::start`]).
    pub fn start(&self, options: StartOptions) -> Result<RunHandle, Error> {
        let job = self.job.clone();
        let handle = self.client.call(async move { job.start(options).await })?;
        Ok(RunHandle { handle, client: self.client.clone() })
    }

    /// A handle on a run this job started elsewhere (see [`crate::Job::resume`]).
    pub fn resume(&self, run_id: &str) -> Result<RunHandle, Error> {
        let (job, run_id) = (self.job.clone(), run_id.to_string());
        let handle = self.client.call(async move { job.resume(&run_id).await })?;
        Ok(RunHandle { handle, client: self.client.clone() })
    }
}

/// A run to finish later, on the blocking client (see [`crate::RunHandle`]).
#[derive(Clone, Debug)]
pub struct RunHandle {
    handle: crate::RunHandle,
    client: Client,
}

impl RunHandle {
    /// The run's id.
    pub fn id(&self) -> &str {
        self.handle.id()
    }

    /// Whether the run can still be finished.
    pub fn is_active(&self) -> bool {
        self.handle.is_active()
    }

    /// Adds a line of output.
    pub fn log(&self, line: impl fmt::Display) {
        self.handle.log(line);
    }

    /// Reports a number for this run.
    pub fn metric(&self, name: &str, value: f64) -> Result<(), Error> {
        self.handle.metric(name, value)
    }

    /// See [`crate::RunHandle::flush`].
    pub fn flush(&self) {
        let handle = self.handle.clone();
        let _ = self.client.call(async move {
            handle.flush().await;
            Ok(())
        });
    }

    /// See [`crate::RunHandle::finish`].
    pub fn finish(&self) -> Option<Run> {
        let handle = self.handle.clone();
        self.client.call(async move { Ok(handle.finish().await) }).ok().flatten()
    }

    /// See [`crate::RunHandle::finish_with`].
    pub fn finish_with<T: std::any::Any + Send + 'static>(&self, result: T) -> Option<Run> {
        let handle = self.handle.clone();
        self.client.call(async move { Ok(handle.finish_with(result).await) }).ok().flatten()
    }

    /// See [`crate::RunHandle::fail`].
    pub fn fail<E: fmt::Display + ?Sized>(&self, err: &E) -> Option<Run> {
        let handle = self.handle.clone();
        let text = err.to_string();
        let name = std::any::type_name::<E>();
        self.client.call(async move { Ok(handle.fail_named(name, &text).await) }).ok().flatten()
    }
}
