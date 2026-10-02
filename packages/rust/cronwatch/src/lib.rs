//! CronWatch for Rust: know when your cron jobs fail, run late or never run.
//!
//! The same library as `@cronwatch/sdk`, the library behind
//! [cronwatch.dev](https://cronwatch.dev): it
//! records each run of a job in a store the app already has, judges it
//! (failed, stuck, slow, over budget, under floor, missed its schedule), and
//! sends one alert when a condition opens and one recovery when it closes. A
//! Rust process shares a store with Node, Ruby, Python, PHP and Go processes
//! byte for byte.
//!
//! ```no_run
//! use cronwatch::{Client, JobOptions};
//! use std::time::Duration;
//!
//! # async fn build_report() -> Result<String, std::io::Error> { Ok(String::new()) }
//! # async fn example() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
//! let cw = Client::builder().retention("30d").build()?;
//! let nightly = cw.job(
//!     "nightly-report",
//!     JobOptions::new().schedule("0 2 * * *").timezone("UTC").grace("15m").expect("Report written"),
//! )?;
//! nightly
//!     .run(|job| async move {
//!         let path = build_report().await?;
//!         job.log(format!("Report written: {path}"));
//!         job.metric("cost", 1.2)?;
//!         Ok::<_, Box<dyn std::error::Error + Send + Sync>>(())
//!     })
//!     .await?;
//! cw.check().await?; // missed and stuck runs, retries, pruning
//! cw.start_checking(Duration::from_secs(60)); // or check every minute in a task
//! # Ok(())
//! # }
//! ```
#![forbid(unsafe_code)]

pub mod bridge;
mod check;
mod client;
#[cfg(test)]
mod conformance;
mod deliver;
mod env;
mod error;
mod evaluate;
mod format;
#[cfg(fuzzing)]
#[doc(hidden)]
pub mod fuzz;
mod handle;
mod handler;
pub mod js;
mod jsre;
mod memory;
mod options;
mod output;
mod panics;
mod run;
mod schedule;
#[cfg(feature = "serde")]
mod serde_impls;
mod serialize;
mod stats;
mod store;
mod types;
pub mod web;

#[cfg(any(feature = "alerts", feature = "triage"))]
pub mod alerts;
#[cfg(feature = "blocking")]
pub mod blocking;
#[cfg(feature = "storetest")]
pub mod storetest;
#[cfg(feature = "triage")]
pub mod triage;

pub use check::JobWithRuns;
pub use client::{Client, ClientBuilder};
pub use deliver::{Channel, ChannelContext, Console, Source, Triage, TriageContext, channel_fn, triage_fn};
pub use error::Error;
pub use handle::{RESERVED_RUN_ID_PREFIX, RunHandle};
pub use handler::{Handler, HandlerOptions};
pub use memory::MemoryStore;
pub use options::{Deliver, DurationSpec, JobOptions};
pub use panics::capture_panic_frames;
pub use run::{Job, JobContext, RecordOptions, RunOptions, StartOptions, current};
pub use serialize::Matcher;
pub use store::{BoxError, BoxFuture, Store, Unsupported, is_unsupported};
pub use types::{
    Alert, AlertDetails, AlertType, BudgetBreach, CheckResult, Condition, Definition, JobHealth, JobState, JobSummary,
    JsonError, MAX_DURATION_MS, Metrics, OpenCondition, Run, RunStatus, SendingAlert, Stats, StoredJob,
};

/// The default redaction: it blanks values that look like secrets
/// (secret-named pairs, credentials in URLs, authorization headers, private
/// keys, JWTs, webhook URLs, and common API key formats), exactly as the
/// SDK's default does. A [`ClientBuilder::redact`] function can call it and
/// add its own patterns on top.
pub fn redact_secrets(text: &str) -> String {
    output::redact_secrets(text)
}

/// What the workspace's other crates (`cronwatch-sqlx`, the scheduler
/// integrations) share with this one. Hidden, and outside the 1.x promise.
#[doc(hidden)]
pub mod __private {
    pub use crate::client::describe_job;
    pub use crate::types::{run_duration, state_version};
}

/// The stored definition `options` give a job named `name`, without a
/// client.
#[doc(hidden)]
#[deprecated(note = "no longer part of the API; documented before 1.0, so it still works through 1.x and goes in 2.0")]
pub fn describe_job(name: &str, options: &JobOptions) -> Definition {
    client::describe_job(name, options)
}

/// How long a run took, held from 0 to [`MAX_DURATION_MS`].
#[doc(hidden)]
#[deprecated(note = "internal, outside the 1.x promise; no longer public from 1.0")]
pub fn run_duration(started_at: i64, finished_at: i64) -> i64 {
    types::run_duration(started_at, finished_at)
}

/// The version a stored state's `version` value counts as.
#[doc(hidden)]
#[deprecated(note = "internal, outside the 1.x promise; no longer public from 1.0")]
pub fn state_version(version: Option<&js::Value>) -> i64 {
    types::state_version(version)
}

/// The release this crate is, the same as every CronWatch package's.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
