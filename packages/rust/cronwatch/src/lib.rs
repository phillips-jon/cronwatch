//! CronWatch for Rust: know when your cron jobs fail, run late or never run.
#![forbid(unsafe_code)]

pub mod js;

/// The release this crate is, the same as every CronWatch package's.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
