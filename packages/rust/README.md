# cronwatch for Rust

Cron and scheduled-job monitoring that lives inside your Rust service. Wrap a job once; every run is recorded in a database you already have, and you are told when a run is missed, fails, gets stuck, runs slow, goes over budget or quietly does nothing. No server to run, no account to make. This is the library behind [cronwatch.dev](https://cronwatch.dev).

This is the Rust port of [`@cronwatch/sdk`](https://www.npmjs.com/package/@cronwatch/sdk): the same rules, the same alert text and the same stored rows, so a Rust process and a Node, Ruby, Python, PHP or Go process can share one database, and every port reads the tables the others write. It has the core (jobs, runs, runs that span calls, checks, silences, sources, deferred delivery and the triage hook), the memory store, the blocking client, the SQL store in `cronwatch-sqlx` (SQLite, Postgres, MySQL and MariaDB) with the pg_cron source, the alert channels, Claude triage, the dashboard and its JSON API, and a job's HTTP handler for a platform cron, each framework-free with tower and axum adapters, and the scheduler integrations for tokio-cron-scheduler and apalis ([DESIGN.md](https://github.com/phillips-jon/cronwatch/blob/main/packages/rust/DESIGN.md) has how each part works).

Docs: [cronwatch.dev](https://cronwatch.dev/docs/)

## Install

Rust 1.85 or newer for `cronwatch`, `cronwatch-tokio-cron-scheduler` and `cronwatch-apalis`; `cronwatch-sqlx` needs 1.94, as sqlx 0.9 does. The core depends on tokio, `getrandom`, `jiff`, `sha2` (the dashboard's cookie) and `md-5` (the app tag the scheduler integrations share) and nothing else: cron expressions are read by a port of [croner](https://github.com/hexagon/croner) (the parser the SDK uses), so every port agrees on every fire time. The `alerts` and `triage` features add reqwest on rustls (whose aws-lc-rs needs a C compiler) and `url`, and `alerts` also `hmac` (the webhook's signature and SES's SigV4); `tower` adds `http`, `http-body`, `http-body-util`, `bytes` and `tower-service`, and `axum` adds axum itself. `regex` lets `expect_match` take a `regex::Regex`, and `serde` gives the public types `Serialize` and `Deserialize` (the SDK's JSON, field for field) for your own use.

```toml
[dependencies]
cronwatch = "0.11"
cronwatch-sqlx = { version = "0.11", features = ["sqlite"] } # or "postgres", "mysql", "pgcron"
sqlx = { version = "0.9", default-features = false, features = ["runtime-tokio", "sqlite"] }
tokio = { version = "1", features = ["macros", "rt-multi-thread"] }
```

The crates are released together at one version: `cronwatch-sqlx` and the scheduler crates each require `cronwatch` at exactly their own version, so upgrade them together.

## Use

```rust,no_run
use cronwatch::{Client, JobOptions};
use cronwatch_sqlx::SqlStore;
use sqlx::sqlite::{SqliteConnectOptions, SqlitePool};
use std::time::Duration;
# async fn page(_title: &str, _message: &str) -> Result<(), cronwatch::BoxError> { Ok(()) }
# async fn build_report(_job: cronwatch::JobContext) -> Result<String, std::io::Error> { Ok(String::new()) }

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
# use std::time::Duration;
# fn doc(cw: cronwatch::Client) {
cw.start_checking(Duration::from_secs(60)); // a task that checks every minute
# }
```

A program a crontab runs checks from a second crontab line instead, `cw.check().await?`, on the same database. Without a runtime of its own, it can use the blocking client (the `blocking` feature):

```rust
# use cronwatch::JobOptions;
# fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
let cw = cronwatch::blocking::Client::new(cronwatch::Client::builder())?;
let job = cw.job("backup", JobOptions::new().schedule("0 3 * * *").timezone("UTC"))?;
job.run(|run| {
    run.log("copied");
    Ok::<_, std::io::Error>(())
})?;
# Ok(())
# }
```

## Alerts

With the `alerts` feature, `cronwatch::alerts` has the SDK's channels: Slack, Discord, a signed webhook, email through Resend, Postmark, SendGrid, Mailgun or SES, Twilio SMS, and Sentry, Honeybadger, Datadog, Rollbar, Bugsnag and New Relic. With `triage`, `cronwatch::triage::anthropic` adds a short diagnosis from Claude to each alert.

```rust
use cronwatch::alerts::{self, SlackOptions};
use cronwatch::triage::{self, AnthropicOptions};
# use cronwatch::Client;
# fn doc() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {

let cw = Client::builder()
    .alert(alerts::slack(SlackOptions::new().webhook_url(std::env::var("SLACK_WEBHOOK_URL")?))?)
    .triage(triage::anthropic(AnthropicOptions::new().context("An axum service on Postgres."))?) // reads ANTHROPIC_API_KEY
    .build()?;
# Ok(())
# }
```

Every request refuses redirects, reads at most 1 MiB of an answer, and names only the URL's origin in an error. A channel's request ends after ten seconds; triage's has a deadline of its own, 24 seconds, and the alert goes out without a diagnosis rather than wait longer.

## Dashboard

`cw.routes(options)` is the dashboard and a small JSON API (the SDK's `cw.routes()`): the board with every job's last day, a page per job with its week, runs and output, silence, forget and a check, and the API `@cronwatch/mcp` talks to. It is installable as an app (a manifest, icons, a service worker and an offline page), needs no script of its own, and sends a strict Content Security Policy. With the `axum` feature, nest it anywhere and it finds its base path from the mount:

```rust
use cronwatch::web::RoutesOptions;
# fn doc(cw: cronwatch::Client) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {

let routes = cw.routes(RoutesOptions::new().token(std::env::var("CRONWATCH_TOKEN")?))?;
let app = axum::Router::new().nest_service("/cronwatch", routes);
# let _: axum::Router = app;
# Ok(())
# }
```

Send the token as `Authorization: Bearer <token>`, or open the dashboard once with `?token=<token>` and a cookie keeps you signed in. Without a token it answers 503, except in development (`CRONWATCH_ENV`, `APP_ENV` or `RUST_ENV` set to `development`, `dev`, `local`, `test` or `testing`), where it makes one and prints a sign-in link on its first request; `RoutesOptions::no_token()` serves it open behind your own auth. Writes from another site are refused. Behind a proxy, `origin("https://app.example.com")` or `trust_proxy()` says what the browser sees. With the `tower` feature `Routes` is a `tower::Service` for hyper, tonic or anything else built on tower; without it, `routes.handle(web::Request)` answers a `web::Response` for a framework of your own.

## Handler

`job.handler(fn, options)` is the job as an HTTP endpoint for a platform cron that calls a URL (the SDK's `job.handler()`): each request carrying `Authorization: Bearer <CRON_SECRET>` runs the function as a recorded run and is answered with how it went.

```rust
use cronwatch::HandlerOptions;
# async fn build_report(_job: cronwatch::JobContext) -> Result<String, std::io::Error> { Ok(String::new()) }
# fn doc(nightly: cronwatch::Job) {

let handler = nightly.handler(|job, _request| async move { build_report(job).await }, HandlerOptions::new());
let app = axum::Router::new().route_service("/api/cron/nightly", handler);
# let _: axum::Router = app;
# }
```

It is a tower service too, so on AWS Lambda `lambda_http::run(handler)` serves it (and `lambda_http::run(routes)` the dashboard) with no code of the crate's own. An EventBridge Scheduler invoking the function directly sends no bearer, so give that handler `HandlerOptions::new().no_secret()`.

## Runs that span calls

A run started in one place and finished in another (a queue's callback, another process) uses a handle:

```rust
# async fn doc(cw: cronwatch::Client, job: cronwatch::Job) -> Result<(), cronwatch::Error> {
let run = job.start(cronwatch::StartOptions::new().id("evt-1")).await?;
run.log("loaded 40 recipients");
run.flush().await;
// later, perhaps elsewhere:
let run = cw.resume_run("digest", "evt-1").await?;
run.finish().await;
# Ok(())
# }
```

## Schedulers

A service that runs its jobs from a scheduler watches them through the scheduler's crate: each job is declared with the scheduler's schedule, every run is recorded, and a job the scheduler no longer has keeps its runs and loses its schedule, so it is never reported missed.

- [`cronwatch-tokio-cron-scheduler`](https://crates.io/crates/cronwatch-tokio-cron-scheduler): `watcher.job(name, "0 0 2 * * *", "UTC", |job| async move { .. }, options)` stands in for `Job::new_async_tz`, each schedule checked against the scheduler's own fire times.
- [`cronwatch-apalis`](https://crates.io/crates/cronwatch-apalis): a tower layer that records each attempt of a worker's tasks as a run (retries included, one alert for the failures and a recovery for the success), and `watcher.cron(name, "0 2 * * *", "Europe/London", options)`, apalis-cron's backend on CronWatch's own schedule. apalis 1.0 is at release candidates; the crate is pinned to them, and stays below 1.0, outside the promise, until apalis 1.0 is final.

Both are built on `cronwatch::bridge`, which is for integration authors and outside the 1.x promise.

A program a crontab runs needs neither: [`examples/crontab`](https://github.com/phillips-jon/cronwatch/tree/main/packages/rust/examples/crontab) is a job and its check from two crontab lines on one SQLite file.

## Changes for 1.0

1.0 promises the names this README and the [Rust docs](https://cronwatch.dev/docs/rust/) document, the stored data, the dashboard's JSON API and the webhook's payload. Getting there changed a few things in this release.

**Breaking, for code that builds these types with a struct literal.** They are `#[non_exhaustive]` now, so a later 1.x can add a field without breaking your build:

- `Run`, `StoredJob`, `OpenCondition`, `SendingAlert`, `BudgetBreach`, `Alert`, `JobState`, `Stats`, `JobSummary`, `CheckResult`, `JobWithRuns`, `TriageContext`, `alerts::Request` and `alerts::Response`: make one with `Run::new(id, job, status, started_at)`, `StoredJob::new(definition, created_at, updated_at)`, `OpenCondition::new`, `SendingAlert::new`, `BudgetBreach::new`, `Alert::new(type, job, details, at)`, `TriageContext::new`, `alerts::Request::new` or `Response::new` and set the rest of its fields, or read one with `from_json`.
- `AlertDetails`'s variants: make one with `AlertDetails::missed`, `failure`, `slow`, `over_budget`, `under_floor` or `recovered`, and match with `..`.
- Every channel's options (`SlackOptions`, `DiscordOptions`, `WebhookOptions`, `EmailOptions`, `ResendOptions`, `PostmarkOptions`, `SendgridOptions`, `MailgunOptions`, `SesOptions`, `TwilioOptions`, `SentryOptions`, `HoneybadgerOptions`, `DatadogOptions`, `RollbarOptions`, `BugsnagOptions`, `NewRelicOptions`), `triage::AnthropicOptions`, `cronwatch_sqlx::PgCronOptions` and the integrations' `Options`: start from `new()` and set fields with the builder method named after each, `SlackOptions::new().webhook_url(url)` where you wrote `SlackOptions { webhook_url: url, ..Default::default() }`. `cronwatch_sqlx::PgCronJob` is read only.
- `js::parse` answers `JsonError`, the error every `from_json` answers, where it answered `js::ParseError`.

**On the wire.** The dashboard API's silence and unsilence answer `{"ok":true,"job":<summary>}` where they answered the stored state, and `GET <base>/api` names the library, its language and version. The webhook's body starts with `"schema": 1`. `record_run` refuses a run id longer than 200 characters, as `start` does.

**Deprecated**, each still working and marked `#[deprecated]` so the compiler says what to use:

| Deprecated | Use instead | Goes in |
|---|---|---|
| `Client::start(every)`, `blocking::Client::start(every)` | `start_checking(every)`: a job's `start` opens a run, so the client's is named for what it starts | 2.0 |
| `Routes::into_router()` | `Router::new().nest_service("/cronwatch", routes)`: axum is below 1.0, so its types stay out of this crate's API | 1.0 |
| `ReqwestTransport::with_client(client)` | the default transport (`transport: None`, which honours `HTTP_PROXY`, `HTTPS_PROXY` and `NO_PROXY`), or a `Transport` of your own: reqwest is below 1.0 | 1.0 |
| `describe_job(name, &options)` | nothing: documented before 1.0, so it stays through 1.x | 2.0 |
| `run_duration`, `state_version`; `js::ParseError`; `alerts::MAX_SEGMENTS`, `alerts::post::{TIMEOUT, MAX_BODY, origin}`; `triage::{SYSTEM, REQUEST_TIMEOUT, FALLBACK_BETA}`; `cronwatch_sqlx::pgcron::{HOLD, schedule, job_name, run_of}` | nothing: internal, public by accident (`JsonError` for `ParseError`) | 1.0 |
| everything in `storetest` but `run` (`replay_fixture`, `finish_once`, `Shared`, `Clock`, `T0` and the other fixture helpers) | `storetest::run`, the contract test | 1.0 |

`cronwatch::bridge`, which the scheduler integrations are built on, is for integration authors and outside the promise. `cronwatch-apalis` stays below 1.0 while apalis is a release candidate.

## Testing

`cargo test --workspace --all-features` in `packages/rust`. The dashboard's tests replay the SDK's answers (`packages/ruby/test/web/golden.json`) straight into `Routes::handle`, through the tower service and through a real server with the dashboard nested in axum; the ones that need an environment of their own (development, a missing token) run in a child process of the test binary, as do the Lambda tests, against a fake Lambda runtime API. `CRONWATCH_TEST_RUST=1 npm test --workspace packages/mcp` at the repository root drives `@cronwatch/mcp` against the dashboard `webserver` serves (`cargo run -p cronwatch-webserver -- PORT`). The Postgres, MySQL, MariaDB and pg_cron tests run when `CRONWATCH_TEST_PG`, `CRONWATCH_TEST_MYSQL`, `CRONWATCH_TEST_MARIADB` and `CRONWATCH_TEST_PGCRON` hold URLs of servers to use (`postgres://...`, `mysql://...`), and say they skipped otherwise; `CRONWATCH_TEST_PG` also runs `cronwatch-apalis` over apalis's Postgres storage. The scheduler tests run real schedulers on the wall clock, a few seconds in all. The workspace's `.cargo/config.toml` sets `TZ=UTC`, as the conformance fixtures are made. The croner parity check and the SQLite file shared with Node run when `node` and the built SDK (`npm run build --workspace packages/sdk`) are there, and skip with the reason otherwise. Every README's examples are doc tests, compiled with the rest of the suite. `packages/rust/fuzz` has cargo-fuzz targets for what reads untrusted input (JSON, durations, cron schedules, `jsre` patterns, a dashboard request, stored rows): `cargo +nightly fuzz run <target>` there, after `cargo install cargo-fuzz`. CI also runs the tests on macOS and Windows, checks each feature alone (`cargo hack`), the docs with warnings denied, the packaged crates and the lowest versions the manifests allow, and runs the fuzz targets once a week.
