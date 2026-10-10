---
title: Rust schedulers
description: Watch tokio-cron-scheduler and apalis: jobs declared with the scheduler's own schedules, checked against its fire times, every run and retry recorded, and the check running beside them.
order: 3.92
group: Rust
---

# Rust schedulers

A scheduler your Rust service already runs is watched through a crate of its own, so an app pulls in only the one it uses and the core crate stays small. Everything else (the client, the store, the channels, the dashboard) is the [Rust page](/docs/rust/).

```bash
cargo add cronwatch-tokio-cron-scheduler   # or cronwatch-apalis
```

| Scheduler | Crate | Supported | What you add |
|---|---|---|---|
| [tokio-cron-scheduler](#tokio-cron-scheduler) | `cronwatch-tokio-cron-scheduler` | 0.15 | `watcher.job(...)` for `Job::new_async_tz` |
| [apalis](#apalis) | `cronwatch-apalis` | 1.0.0-rc.10, apalis-cron 1.0.0-rc.9 | `watcher.cron(...)` as a worker's backend, and `watcher.layer()` |

Both need Rust 1.85 or newer. A program that a crontab runs needs no integration: see [Run the check](/docs/rust/#run-the-check) on the Rust page.

## What every integration does

- **Jobs are declared from the scheduler.** Each job you make through the integration is a CronWatch job with the schedule you gave the scheduler, so a job that stops running is reported missed without you writing a cron expression twice. Where the scheduler reads the expression itself, it is checked against the scheduler's own fire times; one that differs is reported once to the error handler and the job is watched without a schedule, so its failures, duration, and budgets still alert but it is never reported missed.
- **Jobs gone lose their schedule.** A job taken out of the scheduler, in this process or since an earlier deploy, is declared again without its schedule and with ` (no longer scheduled)` after its description, so it keeps its history and is never reported missed; a missed alert already open closes with a recovery.
- **Runs and jobs say where they came from.** Each run an integration records has its name as the run's trigger (`tokio-cron-scheduler`, `apalis`), and job names are the ones you give (for apalis, the worker's name), never prefixed. These spellings are stored, so they do not change within a major release; see [Triggers, tags, and job names](/docs/dashboard/#triggers-tags-and-job-names).
- **Jobs belong to an app.** Every job is tagged with the integration (`tokio-cron-scheduler`, `apalis`) and the app (`apalis:billing`), so two apps sharing a store never take each other's jobs for gone. The app is `Options::app`, else `CRONWATCH_APP_ID`, else the running executable's file name. Set `CRONWATCH_APP_ID` when one app's processes are different executables, or two apps' executables share a name.
- **Nothing runs unwatched.** A name or option CronWatch refuses is an error from the constructor, with the SDK's message, and nothing is made. So is a schedule the scheduler refuses, and for apalis, whose worker runs on CronWatch's own reading of the expression, one CronWatch refuses. tokio-cron-scheduler reads the expression itself, so one it takes and CronWatch cannot read is reported once and its job watched without a schedule, as one whose fire times differ is.
- **Declarations reach the store** in the background. Each watcher's `wait().await` waits for those writes, for tests and a clean exit.
- **Options per job.** `Options::new().defaults(...)` are job options for every job, and each constructor takes the job's own `JobOptions` after them. `Options` is `#[non_exhaustive]`: start from `Options::new()` and set `app` and `defaults` (and, for apalis, `job(name, options)`) with its builder methods.
- **Built on `cronwatch::bridge`**, which a scheduler integration of your own can use too. It is for integration authors and outside the 1.x promise: it may change in a minor release.

### Retries

For apalis, every attempt is a run of its own. An attempt that fails (an error, or a panic) is a failed run with its cause, so failing attempts open one failed alert and the attempt that succeeds closes it with a recovery; `failures_before_alert(3)` counts failed attempts in a row. An attempt the queue gives back without failing (a task put back as pending, or cancelled while it ran) did not fail and did not do its work: its run is taken back with `Job::run_or_discard`, so nothing is judged, no alert is sent, and the failures in a row are left as they were. If that job was due, its schedule reports it missed. Taking a run back needs a store with `delete_run_if`, which the memory store and `cronwatch-sqlx` have.

### The check

Each integration has a check job of its own, which also declares again without their schedules the jobs this app's scheduler no longer runs. A service can just as well call `cw.start_checking(Duration::from_secs(60))` beside the scheduler.

## tokio-cron-scheduler

```rust
use cronwatch::{Client, JobOptions};
use cronwatch_tokio_cron_scheduler::{Options, Watcher};
use std::time::Duration;
use tokio_cron_scheduler::JobScheduler;

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
scheduler.add(watcher.check_job(Duration::from_secs(60))?).await?; // or cw.start_checking(...)
watcher.follow(&scheduler);
scheduler.start().await?;
```

tokio-cron-scheduler names a job only by a UUID and runs a closure that returns nothing, so its own notifications cannot tell a failed run from a good one. The watcher stands in for its constructors instead: `watcher.job(name, schedule, zone, f, options)` is `Job::new_async_tz` with a name, and `watcher.repeated(name, every, f, options)` is `Job::new_repeated_async`, declared `every <interval>` in whole seconds, as the scheduler counts them. Each returns the scheduler's own `Job` for `scheduler.add`. The closure gets the run's `JobContext` and returns a `Result`: an `Err` fails the run, a `String` returned is its output when nothing was logged, and a panic is recorded as a failed run before it goes on to tokio. The context is also `cronwatch::current()`. One-shot jobs are not watched.

**Schedules.** The expression is given to both unchanged. tokio-cron-scheduler reads it with the `croner` crate and CronWatch with its port of croner, the parser the SDK uses, which differ in places: tokio-cron-scheduler asks for six fields, seconds first, and matches a day of the month and a day of the week together, where croner matches either. Each schedule is checked against the scheduler's own fire times; one that differs (`0 0 0 1 * MON`, say) is reported once and its job watched without a schedule.

**Zones.** tokio-cron-scheduler 0.15 reads a job made in a zone at the offset the zone had when the job was made, until the process restarts: after its first run, a job in `America/New_York` made in summer runs at -04:00 all winter. CronWatch expects what the scheduler does, so a zone with daylight saving is declared at that fixed offset (`Etc/GMT+4`, or `+05:30` for an offset in part of an hour) and the move is reported once. Give such a job a zone without daylight saving, such as UTC, to keep it at one time of day. The zone is an IANA name, matched without regard to case; `""` or `"UTC"` is UTC, the scheduler's default.

**Jobs gone.** tokio-cron-scheduler does not announce a removal, so `watcher.follow(&scheduler)` listens on the scheduler's own channels for jobs made and deleted: a job made here that the scheduler deletes is declared again without its schedule at once. `follow` spawns a task and returns its `JoinHandle`; the task runs until you abort it or the runtime ends. Without it, `watcher.sync(&scheduler).await`, which the check job runs, finds a job the scheduler no longer has by asking it for each job's next tick. A sync also takes the schedule out of each job of this app's that the store holds and no job made here has.

**The check.** `watcher.check_job(every)` is a repeated job that runs a sync and a check, never a job itself.

## apalis

```rust
use apalis::prelude::*;
use apalis_cron::Tick;
use cronwatch::{Client, JobOptions};
use cronwatch_apalis::{Options, Watcher};
use std::time::Duration;

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
```

apalis 1.0 has not shipped: the crate is built against its release candidates, pinned exactly (`apalis` and `apalis-core` 1.0.0-rc.10, `apalis-cron` 1.0.0-rc.9), since each candidate has changed the API, so pin the same ones. Unlike the other CronWatch crates, `cronwatch-apalis` stays below 1.0 while apalis is a release candidate, outside 1.0's promise: a release of it may change its API to follow a new candidate. It joins the promise once apalis 1.0 is final.

```toml
[dependencies]
cronwatch = "0.12"
cronwatch-apalis = "0.12"
apalis = "=1.0.0-rc.10"
apalis-cron = "=1.0.0-rc.9"
```

**Schedules.** `watcher.cron(name, expr, zone, options)` declares the job and gives apalis-cron a schedule that is CronWatch's own reading of the expression, so the worker runs on exactly the fire times CronWatch expects and nothing needs checking; an expression or zone CronWatch cannot read is an error from `cron`, and nothing is made. Five or six fields, nicknames, and `every 5m` all work, in any IANA zone (`""` for the process's own). `cronwatch_apalis::schedule(expr, zone)` is the same schedule without a declaration. With the crate's `cron` feature (Rust 1.87), `watcher.cron_schedule(name, schedule, tz, options)` takes a `cron::Schedule`, which apalis-cron runs itself, and declares its source text once it is checked against the `cron` crate's own fire times; one that differs (the `cron` crate counts the days of the week from 1, Sunday) is reported once and watched without a schedule. apalis-cron's English routines and builder have no text CronWatch reads, so a worker on one is watched through the layer without a schedule.

**Runs.** `watcher.layer()` is a tower layer for `WorkerBuilder::layer` that records each attempt of the worker's tasks as a run (trigger `apalis`) of the job named after the worker; `watcher.layer_for(name)` names it. The handler finds the run with `cronwatch::current()` to log and add metrics. Added after `.retry(...)`, it sits inside the retry layer, so every attempt is a run of its own and retries follow [the rule above](#retries). A panic is a failed run and carries on to apalis's `catch_panic`. A `DeferredError` or `RetryAfterError`, which put the task back as pending, and a task cancelled while it ran are given back; an `AbortError` a task returns to stop its retries is a failure.

**Queued tasks and workers elsewhere.** The layer works over any backend, so a worker on apalis's Postgres, MySQL, SQLite, or Redis storage records its tasks the same way. A worker whose job this process did not declare (queued tasks, or a worker in a process of its own while another schedules) takes the definition the store holds when it is this app's, so the schedule another process stored is kept, else `Options::defaults` and its entry in `Options::jobs`, a map of job options by name.

**The check.** `watcher.check_worker(every)` is a cron worker named `cronwatch-check` that syncs and runs a check; run it beside the others. The sync takes the schedule out of each job of this app's that the store holds and no worker made here has. Its runs are never a job.
