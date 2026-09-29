//! A job a crontab runs, watched by CronWatch, and the check a second line
//! of the same crontab runs:
//!
//! ```text
//! # m  h  dom mon dow  command
//! 0    2  *   *   *    /usr/local/bin/crontab report
//! */5  *  *   *   *    /usr/local/bin/crontab check
//! ```
//!
//! Each line starts a process of its own, so the runs and the job's state
//! live in a database both reach: a SQLite file here (`$CRONWATCH_DB`, else
//! `./cronwatch.db`), or the app's Postgres or MySQL through
//! `cronwatch-sqlx`. Both commands declare the job, so the check knows its
//! schedule even before its first run. `report` records its run as it
//! ends; `check` finds the report missed when 02:00 passes without one
//! (after the grace), a run that started and never ended stuck after its
//! timeout, and sends the alerts, printing what it did.
//!
//! A program that stays up (a server, a worker) checks in itself instead,
//! with `cw.start(Duration::from_secs(60))`. Only one process needs to
//! check; running it in every replica of a service is harmless, since a
//! check judges each run once.
#![forbid(unsafe_code)]

use std::io::Write;
use std::time::Duration;

use cronwatch::{Client, JobOptions};
use cronwatch_sqlx::SqlStore;
use sqlx::sqlite::{SqliteConnectOptions, SqlitePool};

type BoxError = Box<dyn std::error::Error + Send + Sync>;

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), BoxError> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let path = std::env::var("CRONWATCH_DB").unwrap_or_else(|_| "cronwatch.db".into());
    run(&args, &path, &mut std::io::stdout()).await
}

/// The command, `report` or `check`, on the SQLite file at `path`.
async fn run(args: &[String], path: &str, out: &mut dyn Write) -> Result<(), BoxError> {
    let [command] = args else {
        return Err("usage: crontab report|check".into());
    };
    if command != "report" && command != "check" {
        return Err("usage: crontab report|check".into());
    }
    let pool = SqlitePool::connect_with(SqliteConnectOptions::new().filename(path).create_if_missing(true)).await?;
    // Alerts go to the console unless channels are given (the alerts feature).
    let cw = Client::builder().store(SqlStore::sqlite(pool)).build()?;

    // The same declaration in both commands: the crontab's line, as a schedule.
    let nightly = cw.job(
        "nightly-report",
        JobOptions::new()
            .schedule("0 2 * * *")
            .timezone("UTC")
            .grace("15m")
            .timeout(Duration::from_secs(30 * 60))
            .expect("Report written"),
    )?;

    let result = if command == "check" {
        let result = cw.check().await?;
        let (jobs, alerts) = (result.jobs.len(), result.alerts.len());
        writeln!(out, "cronwatch: checked {jobs} job{}, sent {alerts} alert{}", plural(jobs), plural(alerts))?;
        Ok(())
    } else {
        // A returned error fails the run and is returned here, so the process
        // exits non-zero, as cron expects.
        nightly
            .run(|job| async move {
                job.log("Report written: 42 rows");
                job.metric("rows", 42.0)?;
                Ok::<_, BoxError>(())
            })
            .await
    };
    cw.close().await?;
    result
}

fn plural(n: usize) -> &'static str {
    if n == 1 { "" } else { "s" }
}
