# cronwatch-tokio-cron-scheduler

[tokio-cron-scheduler](https://crates.io/crates/tokio-cron-scheduler) watched by [`cronwatch`](https://crates.io/crates/cronwatch), the Rust port of the library behind [cronwatch.dev](https://cronwatch.dev): each job is declared as a CronWatch job with its schedule, and every run is recorded, so you are told when one fails, runs late, never runs, gets stuck or runs slow.

tokio-cron-scheduler 0.15, Rust 1.85 or newer.

```toml
[dependencies]
cronwatch = "0.7"
cronwatch-tokio-cron-scheduler = "0.7"
tokio-cron-scheduler = "0.15"
```

tokio-cron-scheduler names a job only by a UUID and runs a closure that returns nothing, so the watcher stands in for its constructors: each job is made with a name, and its closure returns a `Result`.

```rust
use cronwatch::{Client, JobOptions};
use cronwatch_tokio_cron_scheduler::{Options, Watcher};
use std::time::Duration;
use tokio_cron_scheduler::JobScheduler;
# #[derive(Debug)]
# struct ReportError;
# impl std::fmt::Display for ReportError {
#     fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result { f.write_str("no report") }
# }
# async fn build_report() -> Result<String, ReportError> { Ok(String::new()) }
# async fn poll() -> Result<(), std::io::Error> { Ok(()) }
# async fn doc(store: cronwatch::MemoryStore) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {

let cw = Client::builder().store(store).build()?;
let watcher = Watcher::new(&cw, Options::default());
let scheduler = JobScheduler::new().await?;
scheduler
    .add(watcher.job(
        "nightly-report",
        "0 0 2 * * *", // seconds first, as tokio-cron-scheduler reads it
        "UTC",
        |job| async move {
            let path = build_report().await?;
            job.log(format!("Report written: {path}"));
            Ok::<_, ReportError>(())
        },
        JobOptions::new().grace("15m"),
    )?)
    .await?;
scheduler.add(watcher.repeated("poll", Duration::from_secs(300), |_| poll(), JobOptions::new())?).await?;
scheduler.add(watcher.check_job(Duration::from_secs(60))?).await?; // or cw.start(...)
watcher.follow(&scheduler);
scheduler.start().await?;
# Ok(())
# }
```

An `Err` fails the run, a `String` returned is its output when nothing was logged, and a panic is recorded as a failed run before it goes on to tokio. The run's context is also `cronwatch::current()`.

- **Schedules.** The expression is given to both unchanged. tokio-cron-scheduler reads it with the `croner` crate and CronWatch with its port of croner (JavaScript), which differ in places: tokio-cron-scheduler asks for six fields and matches a day of the month and a day of the week together, where croner matches either. Each schedule is checked against the scheduler's own fire times; one that differs is reported once to the client's error handler and its job watched without a schedule, so it is never reported missed.
- **Zones.** tokio-cron-scheduler 0.15 reads a job made in a zone at the offset the zone had when the job was made, until the process restarts. CronWatch expects what the scheduler does: a zone with daylight saving is declared at that offset (`Etc/GMT+4` for New York made in summer) and the move reported once. Use a zone without daylight saving, such as UTC, to keep a job at one time of day.
- **Jobs gone.** A job removed from the scheduler keeps its runs and is declared again without its schedule: at once with `follow`, else at the next `sync`, which the check job runs. A sync also takes the schedule out of each job of this app's that the store holds and no job made here has (one an earlier release scheduled).
- **Apps.** Jobs are tagged `tokio-cron-scheduler` and `tokio-cron-scheduler:<app>`, the app named by `Options::app`, else `$CRONWATCH_APP_ID`, else the executable's file name, so two apps sharing a store never declare each other's jobs without a schedule.

A name or option CronWatch refuses, or a schedule or zone tokio-cron-scheduler refuses, is an error from `job`, and nothing is made. A schedule the scheduler takes but CronWatch cannot read is reported once, like one whose fire times differ, and its job watched without a schedule.

## Tests

`cargo test -p cronwatch-tokio-cron-scheduler` runs a real scheduler on the wall clock (it reads `Utc::now()`), a few seconds in all.

MIT licensed.
