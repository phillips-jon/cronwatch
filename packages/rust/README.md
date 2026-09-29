# cronwatch for Rust

Cron and scheduled-job monitoring that lives inside your Rust service. Wrap a job once; every run is recorded in a database you already have, and you are told when a run is missed, fails, gets stuck, runs slow or goes over budget. No server to run, no account to make. This is the library behind [cronwatch.dev](https://cronwatch.dev), not the hosted cronwatch.io, which is unrelated.

This is the Rust port of [`@cronwatch/sdk`](https://www.npmjs.com/package/@cronwatch/sdk), under way: the same rules, the same alert text and the same stored rows, so a Rust process and a Node, Ruby, Python, PHP or Go process can share one database, and every port reads the tables the others write. It has the core (jobs, runs, runs that span calls, checks, silences, sources, deferred delivery and the triage hook), the memory store, the blocking client, the SQL store in `cronwatch-sqlx` (SQLite, Postgres, MySQL and MariaDB) with the pg_cron source, the alert channels and Claude triage. The dashboard and the scheduler integrations come in later phases ([DESIGN.md](DESIGN.md) has the plan and how each part works). It is not released yet.

Docs: [cronwatch.dev](https://cronwatch.dev/docs/)

## Install

Rust 1.85 or newer for `cronwatch`; `cronwatch-sqlx` needs 1.94, as sqlx 0.9 does. The core depends on tokio, `getrandom` and `jiff` and nothing else: cron expressions are read by a port of [croner](https://github.com/hexagon/croner) (the parser the SDK uses), so every port agrees on every fire time. The `alerts` and `triage` features add reqwest on rustls (whose aws-lc-rs needs a C compiler), `url`, `sha2` and `hmac`.

```toml
[dependencies]
cronwatch = "0.7"
cronwatch-sqlx = { version = "0.7", features = ["sqlite"] } # or "postgres", "mysql", "pgcron"
```

## Use

```rust
use cronwatch::{Client, JobOptions};
use cronwatch_sqlx::SqlStore;
use sqlx::sqlite::{SqliteConnectOptions, SqlitePool};
use std::time::Duration;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let pool = SqlitePool::connect_with(SqliteConnectOptions::new().filename("app.db").create_if_missing(true)).await?;
    let cw = Client::builder()
        .store(SqlStore::sqlite(pool))
        .alert(cronwatch::channel_fn("pager", |alert| async move { page(&alert.title, &alert.message).await }))
        .build()?;

    let nightly = cw.job(
        "nightly-report",
        JobOptions::new()
            .schedule("0 2 * * *")
            .timezone("UTC")
            .grace("15m")
            .timeout(Duration::from_secs(30 * 60))
            .expect("Report written")
            .budget("cost", 2.0),
    )?;

    nightly
        .run(|job| async move {
            let path = build_report(job.clone()).await?; // job.cancelled() resolves at the timeout
            job.log(format!("Report written: {path}")); // kept with the run, shown in alerts
            job.metric("cost", 1.2)?; // watched against budgets and baselines
            Ok::<_, cronwatch::BoxError>(())
        })
        .await?;
    Ok(())
}
```

A job's function returns a `Result`; an `Err` fails the run and comes back from `run`, written `Name: message` with the error type's name. A `String` it returns is the run's output when nothing was logged. A panic is recorded as a failed run and then carries on. Dropping `run`'s future while the function runs records the run as failed at once, rather than leave it to be reported stuck.

Something has to notice a run that never happened. A long-running service checks in itself:

```rust
cw.start(Duration::from_secs(60)); // a task that checks every minute
```

A program a crontab runs checks from a second crontab line instead, `cw.check().await?`, on the same database. Without a runtime of its own, it can use the blocking client (the `blocking` feature):

```rust
let cw = cronwatch::blocking::Client::new(cronwatch::Client::builder())?;
let job = cw.job("backup", JobOptions::new().schedule("0 3 * * *").timezone("UTC"))?;
job.run(|run| {
    run.log("copied");
    Ok::<_, std::io::Error>(())
})?;
```

## Alerts

With the `alerts` feature, `cronwatch::alerts` has the SDK's channels: Slack, Discord, a signed webhook, email through Resend, Postmark, SendGrid, Mailgun or SES, Twilio SMS, and Sentry, Honeybadger, Datadog, Rollbar, Bugsnag and New Relic. With `triage`, `cronwatch::triage::anthropic` adds a short diagnosis from Claude to each alert.

```rust
use cronwatch::alerts::{self, SlackOptions};
use cronwatch::triage::{self, AnthropicOptions};

let cw = Client::builder()
    .alert(alerts::slack(SlackOptions { webhook_url: std::env::var("SLACK_WEBHOOK_URL")?, ..Default::default() })?)
    .triage(triage::anthropic(AnthropicOptions { context: "An axum service on Postgres.".into(), ..Default::default() })?) // reads ANTHROPIC_API_KEY
    .build()?;
```

Every request refuses redirects, ends after ten seconds, reads at most 1 MiB of an answer, and names only the URL's origin in an error.

## Runs that span calls

A run started in one place and finished in another (a queue's callback, another process) uses a handle:

```rust
let run = job.start(cronwatch::StartOptions::new().id("evt-1")).await?;
run.log("loaded 40 recipients");
run.flush().await;
// later, perhaps elsewhere:
let run = cw.resume_run("digest", "evt-1").await?;
run.finish().await;
```

## Testing

`cargo test --workspace --all-features` in `packages/rust`. The Postgres, MySQL, MariaDB and pg_cron tests run when `CRONWATCH_TEST_PG`, `CRONWATCH_TEST_MYSQL`, `CRONWATCH_TEST_MARIADB` and `CRONWATCH_TEST_PGCRON` hold URLs of servers to use (`postgres://...`, `mysql://...`), and say they skipped otherwise. The workspace's `.cargo/config.toml` sets `TZ=UTC`, as the conformance fixtures are made. The croner parity check and the SQLite file shared with Node run when `node` and the built SDK (`npm run build --workspace packages/sdk`) are there, and skip with the reason otherwise.
