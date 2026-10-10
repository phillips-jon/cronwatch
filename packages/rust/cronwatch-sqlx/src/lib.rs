//! CronWatch's SQL store over sqlx: jobs, runs, and state in the app's own
//! database, with the app's pool.
//!
//! ```no_run
//! # #[cfg(feature = "sqlite")]
//! # async fn example() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
//! use cronwatch_sqlx::SqlStore;
//! use sqlx::sqlite::{SqliteConnectOptions, SqlitePool};
//!
//! let pool = SqlitePool::connect_with(SqliteConnectOptions::new().filename("data/app.db").create_if_missing(true)).await?;
//! let cw = cronwatch::Client::builder().store(SqlStore::sqlite(pool)).build()?;
//! # Ok(())
//! # }
//! ```
//!
//! The tables are the SDK's (stores/sql.ts), so a Rust process shares a
//! database with a Node, Ruby, Python, PHP, or Go one. Each database is a
//! feature of the crate: `sqlite`, `postgres`, and `mysql` (MySQL 8.0.13 or
//! newer, or MariaDB 10.6 or newer). `pgcron` adds [`PgCron`], a source that
//! watches pg_cron's jobs.
#![forbid(unsafe_code)]

mod rows;
mod sql;
#[cfg(feature = "sqlite")]
mod sqlite;
#[cfg(any(feature = "sqlite", feature = "postgres", feature = "mysql"))]
mod store;

#[cfg(feature = "pgcron")]
pub mod pgcron;

#[cfg(feature = "pgcron")]
pub use pgcron::{PgCron, PgCronJob, PgCronOptions};
pub use sql::{DEFAULT_PREFIX, Dialect};
#[cfg(any(feature = "sqlite", feature = "postgres", feature = "mysql"))]
pub use store::SqlStore;

// The READMEs' examples, compiled (and those that can, run) as doc tests.
// The workspace's README is the core's, but its examples use this crate, so
// they are tested here.
#[cfg(doctest)]
#[doc = include_str!("../../README.md")]
struct WorkspaceReadme;

#[cfg(doctest)]
#[doc = include_str!("../README.md")]
struct Readme;
