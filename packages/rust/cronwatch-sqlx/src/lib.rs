//! CronWatch's SQL store over sqlx: jobs, runs and state in the app's own
//! database, with the app's pool.
//!
//! ```no_run
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
//! database with a Node, Ruby, Python, PHP or Go one. Each database is a
//! feature of the crate: `sqlite` for now.
#![forbid(unsafe_code)]

mod sql;
#[cfg(feature = "sqlite")]
mod store;

pub use sql::{DEFAULT_PREFIX, Dialect};
#[cfg(feature = "sqlite")]
pub use store::SqlStore;
