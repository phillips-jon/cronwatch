//! Where jobs, runs and state live.

use std::fmt;
use std::future::Future;
use std::pin::Pin;

use crate::types::{Definition, JobState, Run, RunStatus, StoredJob};

/// A boxed future that can be sent across threads, which every trait method
/// of the crate returns so the traits can be used as `Arc<dyn Trait>`.
pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// Any error a store, a channel or a source returns.
pub type BoxError = Box<dyn std::error::Error + Send + Sync + 'static>;

/// What an optional store method answers when the store does not have it;
/// the client then falls back to a read and a write, as the SDK does.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Unsupported;

impl fmt::Display for Unsupported {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("the store does not support this")
    }
}

impl std::error::Error for Unsupported {}

/// Whether a store's error is [`Unsupported`].
pub fn is_unsupported(err: &BoxError) -> bool {
    err.is::<Unsupported>()
}

/// Where jobs, runs and state live. [`MemoryStore`](crate::MemoryStore) is
/// one; `cronwatch-sqlx` keeps them in the app's own database. A store of
/// your own should pass the `storetest` feature's contract test.
///
/// Every method returns a boxed future so the trait is object safe. The
/// three conditional writes are provided methods that answer
/// [`Unsupported`]; a store that can make them in one step overrides them.
pub trait Store: Send + Sync + 'static {
    /// Called once before first use: create tables here.
    fn init(&self) -> BoxFuture<'_, Result<(), BoxError>>;
    fn upsert_job<'a>(&'a self, definition: &'a Definition, now: i64) -> BoxFuture<'a, Result<(), BoxError>>;
    /// `None` when the store does not know the job.
    fn get_job<'a>(&'a self, name: &'a str) -> BoxFuture<'a, Result<Option<StoredJob>, BoxError>>;
    /// Every job, by name in byte order.
    fn list_jobs(&self) -> BoxFuture<'_, Result<Vec<StoredJob>, BoxError>>;
    /// Removes a job, its runs and its state.
    fn delete_job<'a>(&'a self, name: &'a str) -> BoxFuture<'a, Result<(), BoxError>>;
    /// Refuses an id already stored.
    fn insert_run<'a>(&'a self, run: &'a Run) -> BoxFuture<'a, Result<(), BoxError>>;
    /// Writes a run's status, finish, duration, error, output and metrics.
    /// A run that is gone stays gone.
    fn update_run<'a>(&'a self, run: &'a Run) -> BoxFuture<'a, Result<(), BoxError>>;
    /// `None` when there is no such run.
    fn get_run<'a>(&'a self, id: &'a str) -> BoxFuture<'a, Result<Option<Run>, BoxError>>;
    /// A job's newest runs first, at most `limit` of them.
    fn list_runs<'a>(&'a self, job: &'a str, limit: usize) -> BoxFuture<'a, Result<Vec<Run>, BoxError>>;
    fn last_run<'a>(&'a self, job: &'a str) -> BoxFuture<'a, Result<Option<Run>, BoxError>>;
    /// Every run still running, oldest first.
    fn running_runs(&self) -> BoxFuture<'_, Result<Vec<Run>, BoxError>>;
    /// `None` when the job has no state yet.
    fn get_state<'a>(&'a self, job: &'a str) -> BoxFuture<'a, Result<Option<JobState>, BoxError>>;
    /// Writes a job's state unconditionally. Used only when
    /// `compare_and_set_state` is unsupported.
    fn set_state<'a>(&'a self, state: &'a JobState) -> BoxFuture<'a, Result<(), BoxError>>;
    /// Deletes finished runs that started before this time, keeping each
    /// job's newest run, and returns how many.
    fn prune(&self, before: i64) -> BoxFuture<'_, Result<u64, BoxError>>;
    fn close(&self) -> BoxFuture<'_, Result<(), BoxError>>;

    /// Writes the run as `update_run` does, only when its stored status is
    /// one of `from`, in one step (SQL: `UPDATE ... WHERE id = ? AND status
    /// IN (...)`), and says whether it wrote. This is what lets exactly one
    /// of several processes finishing the same run evaluate it.
    fn update_run_if<'a>(&'a self, run: &'a Run, from: &'a [RunStatus]) -> BoxFuture<'a, Result<bool, BoxError>> {
        let _ = (run, from);
        Box::pin(async { Err(Unsupported.into()) })
    }

    /// Writes `state` only when the stored state's version (absent, or no
    /// row at all, counts as 0) equals `expected`, and says whether it wrote.
    fn compare_and_set_state<'a>(&'a self, state: &'a JobState, expected: i64) -> BoxFuture<'a, Result<bool, BoxError>> {
        let _ = (state, expected);
        Box::pin(async { Err(Unsupported.into()) })
    }

    /// Deletes the run `id` only when its stored job is `job` and its status
    /// is `status` (SQL: `DELETE ... WHERE id = ? AND job = ? AND status =
    /// ?`), and says whether it deleted. The SDK has no counterpart: it is
    /// how an attempt a queue gave back without failing leaves no run behind,
    /// as the PHP and Go ports' stores take one back.
    fn delete_run_if<'a>(&'a self, id: &'a str, job: &'a str, status: &'a RunStatus) -> BoxFuture<'a, Result<bool, BoxError>> {
        let _ = (id, job, status);
        Box::pin(async { Err(Unsupported.into()) })
    }
}
