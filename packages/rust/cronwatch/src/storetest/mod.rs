//! The test every CronWatch store passes: the memory store, and
//! `cronwatch-sqlx` on SQLite, Postgres, MySQL, and MariaDB. It is the SDK's
//! store-conformance.ts, step for step. Run it against a store of your own,
//! from a test on a tokio runtime (`#[tokio::test]`):
//!
//! ```no_run
//! # use cronwatch::MemoryStore as MyStore;
//! # async fn my_store_passes_the_contract() {
//! cronwatch::storetest::run(|| MyStore::new()).await;
//! # }
//! ```
//!
//! It panics, as a test's assertion does, at the first thing the store gets
//! wrong. [`run`] is the one promised name here; the fixture helpers this
//! module had before 0.11 are deprecated and go at 1.0.
#![allow(deprecated)]

#[doc(hidden)]
pub mod kit;

use std::future::Future;

use crate::store::Store;
use crate::types::{Definition, JobState, Run, RunStatus};

pub use kit::run;

macro_rules! hidden {
    ($($item:item)*) => {
        $(
            #[doc(hidden)]
            #[deprecated(note = "a fixture helper outside the promise; storetest::run is the contract test, and this goes at 1.0")]
            $item
        )*
    };
}

hidden! {
    pub const T0: i64 = kit::T0;
    pub const FAR_STARTS: [&str; 4] = kit::FAR_STARTS;
    pub type Shared = kit::Shared;
    pub type Clock = kit::Clock;
    pub type Capture = kit::Capture;
    pub type Errors = kit::Errors;
    pub type Process = kit::Process;

    pub fn new_run(id: &str, job: &str, status: RunStatus, started_at: i64) -> Run {
        kit::new_run(id, job, status, started_at)
    }

    pub fn new_run_plain(id: &str, job: &str, status: RunStatus, started_at: i64) -> Run {
        kit::new_run_plain(id, job, status, started_at)
    }

    pub fn definition(text: &str) -> Definition {
        kit::definition(text)
    }

    pub fn state(text: &str) -> JobState {
        kit::state(text)
    }

    pub fn canonical(text: &str) -> String {
        kit::canonical(text)
    }

    #[track_caller]
    pub fn same_json(what: &str, got: &str, want: &str) {
        kit::same_json(what, got, want)
    }

    pub async fn finish_once(shared: impl FnMut() -> kit::Shared) {
        kit::finish_once(shared).await
    }

    pub async fn replay_fixture<S: Store>(fixture: &str, make: impl FnMut() -> S) -> usize {
        kit::replay_fixture(fixture, make).await
    }

    pub async fn replay_foreign_versions<S, F, Fut>(fixture: &str, store: &S, write_raw: F) -> usize
    where
        S: Store,
        F: FnMut(String) -> Fut,
        Fut: Future<Output = ()>,
    {
        kit::replay_foreign_versions(fixture, store, write_raw).await
    }

    pub async fn check_over_foreign_rows<S, F, Fut>(store: S, prefix: &str, exec: F)
    where
        S: Store + 'static,
        F: FnMut(String) -> Fut,
        Fut: Future<Output = ()>,
    {
        kit::check_over_foreign_rows(store, prefix, exec).await
    }

    pub async fn cron_over_foreign_row<S, F, Fut>(store: S, prefix: &str, started_at: &str, exec: F)
    where
        S: Store + 'static,
        F: FnMut(String) -> Fut,
        Fut: Future<Output = ()>,
    {
        kit::cron_over_foreign_row(store, prefix, started_at, exec).await
    }
}
