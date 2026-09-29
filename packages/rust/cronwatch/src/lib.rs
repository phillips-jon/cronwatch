//! CronWatch for Rust: know when your cron jobs fail, run late or never run.
//!
//! The same library as `@cronwatch/sdk`, the library behind
//! [cronwatch.dev](https://cronwatch.dev) (not the hosted cronwatch.io): it
//! records each run of a job in a store the app already has, judges it
//! (failed, stuck, slow, over budget, missed its schedule), and sends one
//! alert when a condition opens and one recovery when it closes. A Rust
//! process shares a store with Node, Ruby, Python, PHP and Go processes byte
//! for byte.
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
//! cw.start(Duration::from_secs(60)); // or check every minute in a task
//! # Ok(())
//! # }
//! ```
#![forbid(unsafe_code)]

mod check;
mod client;
mod deliver;
mod env;
mod error;
mod evaluate;
mod format;
mod handle;
pub mod js;
mod jsre;
mod memory;
mod options;
mod output;
mod panics;
mod run;
mod schedule;
mod serialize;
mod stats;
mod store;
mod types;

#[cfg(feature = "blocking")]
pub mod blocking;
#[cfg(feature = "storetest")]
pub mod storetest;

pub use check::JobWithRuns;
pub use client::{Client, ClientBuilder, describe_job};
pub use deliver::{Channel, ChannelContext, Console, Source, Triage, TriageContext, channel_fn, triage_fn};
pub use error::Error;
pub use handle::{RESERVED_RUN_ID_PREFIX, RunHandle};
pub use memory::MemoryStore;
pub use options::{Deliver, DurationSpec, JobOptions};
pub use panics::capture_panic_frames;
pub use run::{Job, JobContext, RecordOptions, RunOptions, StartOptions, current};
pub use serialize::Matcher;
pub use store::{BoxError, BoxFuture, Store, Unsupported, is_unsupported};
pub use types::{
    Alert, AlertDetails, AlertType, BudgetBreach, CheckResult, Condition, Definition, JobHealth, JobState, JobSummary,
    JsonError, Metrics, OpenCondition, Run, RunStatus, Stats, StoredJob,
};

/// The default redaction: it blanks values that look like secrets
/// (secret-named pairs, credentials in URLs, authorization headers, private
/// keys, JWTs, webhook URLs, and common API key formats), exactly as the
/// SDK's default does. A [`ClientBuilder::redact`] function can call it and
/// add its own patterns on top.
pub fn redact_secrets(text: &str) -> String {
    output::redact_secrets(text)
}

/// The release this crate is, the same as every CronWatch package's.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
