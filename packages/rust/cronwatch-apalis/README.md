# cronwatch-apalis

[apalis](https://crates.io/crates/apalis) watched by [`cronwatch`](https://crates.io/crates/cronwatch), the Rust port of the library behind [cronwatch.dev](https://cronwatch.dev): each attempt of a worker's tasks is recorded as a run through a tower layer, and apalis-cron is given CronWatch's own schedules, so you are told when a job fails, runs late, never runs, gets stuck or runs slow.

apalis 1.0 has not shipped: this crate is built against its release candidates, pinned exactly (`apalis-core 1.0.0-rc.10`, `apalis-cron 1.0.0-rc.9`), since each changes the API. Unlike the rest of the workspace, this crate stays below 1.0 while apalis 1.0 is a release candidate: it is left out of 1.0's promise, and a release of it may change its API to follow a new candidate. It will join the promise once apalis 1.0 is final. Rust 1.85 or newer; the `cron` feature needs 1.87 (the `cron` crate does).

```toml
[dependencies]
cronwatch = "0.7"
cronwatch-apalis = "0.7"
apalis = "=1.0.0-rc.10"
apalis-cron = "=1.0.0-rc.9"
```

```rust
use apalis::prelude::*;
use apalis_cron::Tick;
use cronwatch::{Client, JobOptions};
use cronwatch_apalis::{Options, Watcher};
use std::time::Duration;
# async fn doc(store: cronwatch::MemoryStore) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {

async fn nightly_report(_: Tick) -> Result<(), BoxDynError> {
    if let Some(job) = cronwatch::current() {
        job.log("Report written");
    }
    Ok(())
}

let cw = Client::builder().store(store).build()?;
let watcher = Watcher::new(&cw, Options::default());
let worker = WorkerBuilder::new("nightly-report")
    .backend(watcher.cron("nightly-report", "0 2 * * *", "Europe/London", JobOptions::new().grace("15m"))?)
    .retry(RetryPolicy::retries(3))
    .layer(watcher.layer()) // after .retry, so each attempt is a run
    .build(nightly_report);
tokio::spawn(watcher.check_worker(Duration::from_secs(60))?.run()); // or cw.start_checking(...)
worker.run().await?;
# Ok(())
# }
```

- **Schedules.** `watcher.cron(name, expr, zone, options)` declares the job and gives apalis-cron a schedule that is CronWatch's own reading of it (the port of croner the SDK uses), so the worker runs exactly when CronWatch expects; a name, option, expression or zone CronWatch refuses is an error from `cron`, and nothing is made. `cronwatch_apalis::schedule(expr, zone)` is the same schedule without a declaration. With the `cron` feature, `watcher.cron_schedule(name, schedule, tz, options)` takes a `cron::Schedule`, which apalis-cron runs itself, and declares its source text once it is checked against the `cron` crate's own fire times; one that differs (the `cron` crate counts the days of the week from 1, Sunday) is reported once and watched without a schedule.
- **Runs and retries.** `watcher.layer()` records each attempt as a run (trigger `apalis`) of the job named after the worker; `layer_for(name)` names it. Inside the retry layer every attempt is a run of its own: failing attempts open one failed alert and the one that succeeds closes it. A panic is a failed run and carries on to apalis's `catch_panic`. An attempt apalis gives back without failing (a `DeferredError` or a `RetryAfterError`, which put the task back as pending, or a task cancelled while it ran) leaves no run and closes nothing.
- **Queued tasks and workers elsewhere.** The layer works over any backend (apalis's Postgres, MySQL, SQLite or Redis storage). A worker whose job this process did not declare takes the definition the store holds when it is this app's, so the schedule another process stored is kept, else `Options::defaults` and its entry in `Options::jobs`.
- **The check.** `watcher.check_worker(every)` is a cron worker that syncs and runs a CronWatch check. The sync takes the schedule out of each job of this app's that the store holds and no worker made here has. Its runs are never a job.
- **Apps.** Jobs are tagged `apalis` and `apalis:<app>`, the app named by `Options::app`, else `$CRONWATCH_APP_ID`, else the executable's file name.

## Tests

`cargo test -p cronwatch-apalis --all-features` runs real workers over apalis's memory storage and a cron worker on the wall clock, and, when `CRONWATCH_TEST_PG` names a Postgres (`postgres://...`), over apalis's Postgres storage, in queues of their own whose tasks it deletes at the end. The tests need Rust 1.94, as apalis's Postgres storage brings sqlx 0.9.

MIT licensed.
