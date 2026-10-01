---
title: Rust
description: The cronwatch crate in a Rust service: jobs on tokio, the check, the dashboard nested in axum or served as a tower service, job handlers and AWS Lambda, the sqlx store, alert channels, Claude triage, pg_cron, the blocking client, and sharing one database with the other languages.
order: 3.91
group: Rust
---

# Rust

The `cronwatch` crate is a port of `@cronwatch/sdk`, not a new design. It decides missed, failed, stuck, slow and over budget by the same rules, sends the same alert text, and writes the same rows, so a Rust process can share one database with a Node, Ruby, Python, PHP, Go, Elixir, Java or .NET process and the [MCP server](/docs/mcp/) works against any of them. This page covers the crate itself: a `main` a crontab runs, an axum or other tower service, a Lambda function. tokio-cron-scheduler and apalis have a page of their own: [Rust schedulers](/docs/rust-schedulers/).

```bash
cargo add cronwatch --features alerts
cargo add cronwatch-sqlx --features postgres   # or sqlite, mysql
cargo add sqlx --no-default-features --features runtime-tokio,postgres
cargo add tokio --features macros,rt-multi-thread
```

Rust 1.85 or newer for `cronwatch`; `cronwatch-sqlx` needs 1.94, as sqlx 0.9 does. The core runs on tokio and depends on little else: cron expressions are read by a port of [croner](https://github.com/hexagon/croner), the parser the SDK uses, so every port agrees on every fire time, and zones come from the system's zone database through `jiff`. Everything else is a feature, none on by default:

| Feature | For |
|---|---|
| `alerts` | Slack, Discord, webhook, email, SMS and error tracker channels, over reqwest on rustls (whose aws-lc-rs needs a C compiler) |
| `triage` | Claude triage, over the same transport |
| `tower` | the dashboard and job handlers as `tower::Service`s, for hyper, tonic and `lambda_http` |
| `axum` | `tower`, and the mount point read from axum's nesting, and `Routes::into_router()` |
| `blocking` | a blocking client, for a program with no runtime of its own |
| `regex` | `expect_match` takes a `regex::Regex` |
| `serde` | `Serialize` and `Deserialize` on the public types (the SDK's JSON, field for field), for your own use |
| `storetest` | the contract test for a store of your own |

```toml
[dependencies]
cronwatch = { version = "0.7", features = ["alerts", "axum"] }
cronwatch-sqlx = { version = "0.7", features = ["postgres"] }  # or "sqlite", "mysql", "pgcron"
sqlx = { version = "0.9", default-features = false, features = ["runtime-tokio", "postgres"] }
tokio = { version = "1", features = ["macros", "rt-multi-thread"] }
```

The crates are released together at one version: `cronwatch-sqlx` and the scheduler crates each require `cronwatch` at exactly their own version, so upgrade them together.

## Create one client

```rust
use cronwatch::alerts::{self, SlackOptions};
use cronwatch::{Client, JobOptions};
use cronwatch_sqlx::SqlStore;

let pool = sqlx::PgPool::connect(&std::env::var("DATABASE_URL")?).await?;
let cw = Client::builder()
    .store(SqlStore::postgres(pool)) // or SqlStore::sqlite(pool), SqlStore::mysql(pool)
    .alert(alerts::slack(SlackOptions {
        webhook_url: std::env::var("SLACK_WEBHOOK_URL")?,
        ..Default::default()
    })?)
    .retention("30d")
    .build()?;
```

One client per app, made once at startup and shared: `Client` is a cheap `Clone` handle (an `Arc` inside) and `Send + Sync`, as are its jobs, run handles, job contexts and every store, so put it in your app's state (axum's `State`, a `OnceLock`) and clone it into tasks. `build()` must be called inside a tokio runtime, whose handle the client keeps for the tasks it spawns; outside one it is an error that names the [blocking client](#the-blocking-client). With no options the client keeps everything in memory and writes alerts to the console.

## Declare and run a job

```rust
use std::time::Duration;

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
        let path = build_report().await?;
        job.log(format!("Report written: {path}")); // kept with the run, shown in alerts
        job.metric("cost", 1.2)?; // watched against budgets and baselines
        Ok::<_, cronwatch::BoxError>(())
    })
    .await?;
```

The run is recorded when the function's future finishes. It returns a `Result`: an `Err` is the failure, and `run` hands it back, so your own error handling still works. The error is written `Name: message`, the name being the last segment of the error's type (`ReportError: disk full`), or `Error` for a `Box<dyn Error>`, `anyhow::Error` or a string. A panic is recorded as a failed run (`panic: <message>`) and then carries on, so a run is never left running to be reported stuck later. The store failing never stops a job: store errors go to the error handler (`on_error`, standard error by default), and the job's own outcome is returned.

Declare each job once, at startup, and keep the handle, a cheap `Clone` like the client. Without one, `cw.run("nightly-report", None, f)` declares the job on first use (or again, when given `Some(options)`) and answers `Result<Result<T, E>, cronwatch::Error>`: the outer error is a declaration the SDK refuses, the inner the function's own. A name is 1 to 120 letters, digits, `.`, `_`, `:` or `-`, starting with a letter or digit.

`JobOptions` is a builder whose setters keep the order you call them in, and a stored definition keeps that order, so a Rust process writes the same JSON a Node process does for the same options in the same order. Durations take the SDK's text or a Rust value: `grace("15m")`, `grace(Duration::from_secs(900))` and `grace(900_000)` (milliseconds) are all the same grace. Text is stored as written, a `Duration` as its milliseconds.

A `String` the function returns is the run's output when nothing was logged (and what `expect` checks). An HTTP answer it returns (a `cronwatch::web::Response`, or with `tower` an `http::Response`) with a status of 400 or more fails the run with `HTTP <status> <reason>`; with `tower`, `job.run_http(f)` does the same for an `http::Response` of any body, so a job that calls an API and returns its answer fails when the API does.

The `JobContext` the function gets is a cheap `Clone`, so the future owns it: `name()`, `run_id()`, `started_at()` (epoch milliseconds), `log(line)`, `metric(name, value)` and `metrics(values)`. `log` takes one line, anything with `Display`; format it yourself. The run keeps the last 16 KB. Code deep in a call chain finds the run with `cronwatch::current()`, which is `None` outside one.

### The timeout and dropped futures

`job.cancelled()` resolves when the job passes its `timeout` (an hour by default), and `job.is_cancelled()` says whether it has, the SDK's abort signal. Nothing is interrupted: select on it where the work can stop early, and return an error that says so. A run that goes on past its timeout is marked stuck by the next check; if it finishes later, a late failure is written without a second alert and a late success closes the stuck alert with a recovery.

Rust cancels a future by dropping it, inside `tokio::time::timeout`, say, or in a handler whose client went away. A `run` dropped while the function runs drops the function's future too, and the run is recorded as failed at once (`Cancelled: the run's future was dropped before it finished`) rather than left running. Once the function has returned, what is left (the finish, the state, the alerts) runs in a task of its own, so dropping `run` then cannot lose the record.

## Run the check

A job that never starts cannot report itself, so something has to look. A long-running service (an axum server, a worker, a process running a scheduler) checks in a task:

```rust
cw.start(Duration::from_secs(60)); // until cw.stop() or cw.close()
```

The first check runs a second after `start`, then one every interval (a minute when zero, five seconds at least). A second `start` does nothing, and `stop` lets a check in flight finish. One process checking is enough; running `start` in every replica is harmless, since a check judges each run once. A serverless function does not run between requests, so call `cw.check()` from a cron there instead, or point one at the dashboard's `/api/check`.

A program run from a crontab exits when it is done, so nothing inside it notices the run that never happened. Add a second crontab line that checks, on a store both reach. Both commands declare the job, so the check knows its schedule before its first run:

```
# m  h  dom mon dow  command
0    2  *   *   *    /usr/local/bin/nightly report
*/5  *  *   *   *    /usr/local/bin/nightly check
```

```rust
#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), cronwatch::BoxError> {
    let pool = SqlitePool::connect_with(
        SqliteConnectOptions::new().filename("/var/lib/app/app.db").create_if_missing(true),
    )
    .await?;
    let cw = Client::builder().store(SqlStore::sqlite(pool)).build()?;
    // The same declaration in both commands: the crontab's line, as a schedule.
    let nightly = cw.job(
        "nightly-report",
        JobOptions::new().schedule("0 2 * * *").timezone("UTC").grace("15m"),
    )?;

    let result = match std::env::args().nth(1).as_deref() {
        Some("check") => {
            let result = cw.check().await?;
            println!("checked {} jobs, sent {} alerts", result.jobs.len(), result.alerts.len());
            Ok(())
        }
        // An error fails the run and comes back here, so the process exits non-zero.
        _ => nightly.run(|job| report(job)).await,
    };
    cw.close().await?;
    result
}
```

[`examples/crontab`](https://github.com/phillips-jon/cronwatch/tree/main/packages/rust/examples/crontab) in the repository is this program, with a test that runs its two commands on one SQLite file. `check()` returns a `CheckResult` with `checked_at`, `jobs`, `alerts` and `pruned`; its error is for the store failing as the check starts. Calls at the same time share one check, which runs in a task of its own to the end even when a caller's future is dropped.

## The blocking client

A program with no runtime of its own (a small cron binary, a synchronous app on diesel) uses the blocking client, with the `blocking` feature. It runs a current-thread tokio runtime on a thread of its own, as `reqwest::blocking` does, and a job's function is a plain closure that runs on the calling thread:

```rust
use cronwatch::{blocking, Client, JobOptions};

let cw = blocking::Client::new(Client::builder())?;
let backup = cw.job("backup", JobOptions::new().schedule("0 3 * * *").timezone("UTC"))?;
backup.run(|run| {
    copy_files()?;
    run.log("copied");
    Ok::<_, std::io::Error>(())
})?;
```

`blocking::Client::with_async(|| async { .. })` makes the builder on the client's runtime, for a store that needs a runtime to be made (a sqlx pool). The blocking client has the async client's methods without `.await` (`check`, `jobs`, `silence`, `start`, `close` and the rest); `as_async()` is the async client inside, for what the blocking client does not carry, such as the dashboard's `routes`. It works inside another runtime too, blocking one of its threads, which is best avoided: there, use the async client.

## The dashboard

`cw.routes(options)` is the dashboard and JSON API, the same pages and endpoints as the TypeScript routes, byte for byte: the board's counts by health, a timeline of the last day with a lane per job, the table of every job, and for each job its last seven days, runs and definition, all drawn on the server with no script. With the `axum` feature, nest it in your `Router`:

```rust
use cronwatch::web::RoutesOptions;

let routes = cw.routes(RoutesOptions::new().token(std::env::var("CRONWATCH_TOKEN")?))?;
let app = axum::Router::new()
    .route("/", axum::routing::get(home))
    .nest_service("/cronwatch", routes); // or routes.into_router(), mounted at /cronwatch
```

The base path its links use is found from the mount: axum records the nesting, which the `axum` feature reads, so a mount under a path parameter (`/t/{tenant}/cron`) or nested twice works. `base_path("/ops/cron")` wins over the mount (`""` for the root), and without either the base is `/cronwatch`. `routes.into_router()` is an axum `Router` nested at that base.

With the `tower` feature (which `axum` turns on), `Routes` is a `tower::Service<http::Request<B>>` for any body, answering `http::Response<Full<Bytes>>`, so hyper serves it directly, and so does anything built on tower. Without either feature, `routes.handle(web::Request)` answers a `web::Response`, plain types for an adapter of your own (`web::Request::with_mount` says where it is mounted). actix-web does not use tower; an adapter there would be made on request.

`RoutesOptions`, a builder:

- `token(t)`: the token. Without it the routes read `CRONWATCH_TOKEN`; an empty string counts as unset. Send it as `Authorization: Bearer <token>`, or open the dashboard once with `?token=<token>` and a cookie keeps the browser signed in. Without a token, while the environment is development, the routes make a token of their own and print a sign-in link to standard output on the first request (naming the host only when `origin` is set or the request's host is loopback); anywhere else they answer 503. The environment is the first of `CRONWATCH_ENV`, `APP_ENV` and `RUST_ENV` that is set, and `development`, `dev`, `local`, `test` and `testing` count as development. A debug build is not development.
- `no_token()`: serve the routes to anyone, for a mount behind your own auth.
- `base_path(p)`: the mount, when the adapter cannot tell.
- `origin("https://app.example.com")`: the public origin, pinned whatever a request says, for the cross-site check on writes, the cookie's `Secure` flag, redirects and the sign-in line. An HTTP/1 server does not tell tower whether it came over TLS, so behind TLS set this, or `trust_proxy()`.
- `trust_proxy()`: take the origin from the first `X-Forwarded-Proto` and `X-Forwarded-Host`. Only behind a proxy that sets or overwrites both.

`routes` returns an error only for an `origin` that is not an http or https URL. The token rules, cookie, cross-site rule and every endpoint are the SDK's; see [Dashboard and API](/docs/dashboard/). `/api/check` also accepts the client's cron secret as a bearer, so an outside cron can run the check over HTTP. A body over 1 MiB is answered 413. The dashboard is installable as a web app, with its manifest, icons and service worker under the mount point; see [Install it as an app](/docs/dashboard/#install-it-as-an-app).

## Jobs a URL starts

Some platforms run scheduled work by calling a URL: Cloud Scheduler, a hosting provider's cron, an outside cron service, a crontab line running curl. `job.handler(f, options)` is that endpoint: each request carrying `Authorization: Bearer <secret>` runs `f` as a recorded run, answered with JSON saying how the run went. It is framework-free like the dashboard, and a tower service with the `tower` feature:

```rust
use cronwatch::HandlerOptions;

let handler = nightly.handler(
    |job, _request| async move {
        let path = build_report().await?;
        job.log(format!("Report written: {path}"));
        Ok::<_, ReportError>(())
    },
    HandlerOptions::new(),
);
let app = axum::Router::new().route_service("/api/cron/nightly", handler);
```

The function is given the run's `JobContext` and the `web::Request`. The secret is `HandlerOptions::secret(s)`, else the client's cron secret (`cron_secret(s)` on the builder, which reads `CRON_SECRET` by default), compared in constant time. A wrong or missing bearer is answered 401 and runs nothing. With no secret at all, outside development, the handler answers 503 and reports it once to the error handler, rather than let anyone on the internet run the job; `HandlerOptions::new().no_secret()` (or a client built with `no_cron_secret()`) opts out on purpose, for an endpoint your platform already protects.

A run is answered 200 or 500 with `{"ok","job","run","status","durationMs"}`, and the error's first line as `"error"` for a caller who sent the secret. A function that returns an HTTP answer of its own (a `web::Response`, or an `http::Response`) is answered with it, and a status of 400 or more fails the run. A panic in the function is a failed run, answered 500. The function runs inside the request's future, so a request dropped while it runs records a failed run; spawn the work if it should outlive the request.

### AWS Lambda

A handler and the dashboard are tower services, which is what `lambda_http::run` takes, so AWS Lambda needs no code of the crate's own:

```rust
#[tokio::main]
async fn main() -> Result<(), lambda_http::Error> {
    let cw = Client::builder().store(store().await?).build()?;
    let nightly = cw.job("nightly-report", JobOptions::new().schedule("0 2 * * *").timezone("UTC"))?;
    lambda_http::run(nightly.handler(|job, _| report(job), HandlerOptions::new())).await
}
```

A function EventBridge Scheduler invokes directly has no headers to carry a bearer, and IAM already decides who may invoke it, so give its handler `no_secret()`. Without a server that runs between requests, run the check from a schedule of its own.

## Stores

`MemoryStore` is the default. Nothing survives a restart, so a miss cannot be noticed across one, and each process has its own. When the environment is production (`CRONWATCH_ENV`, `APP_ENV` or `RUST_ENV` set to `production` or `prod`), the client warns once that it is using it.

`cronwatch-sqlx` keeps the same three tables as the SDK's SQL stores in your database, through sqlx 0.9 and the pool you already have. Each database is a feature of the crate:

| Constructor | Feature | |
|---|---|---|
| `SqlStore::sqlite(pool)` | `sqlite` | built from source, so a C compiler is needed; WAL mode, `busy_timeout` 5000, `synchronous` NORMAL |
| `SqlStore::postgres(pool)` | `postgres` | tables made under an advisory lock, so many processes can start at once |
| `SqlStore::mysql(pool)` | `mysql` | MySQL 8.0.13 or newer, or MariaDB 10.6 or newer |

The tables (`cronwatch_jobs`, `cronwatch_runs`, `cronwatch_state`) are made on the client's first use. `.prefix("app_cron_")?` names them: lowercase letters, digits and underscores, not starting with a digit, at most 47 characters (Postgres cuts a name at 63, and the longest the store makes adds 16). On Postgres and MySQL each statement runs on the pool on its own, in autocommit, so a run recorded inside a transaction of yours stays recorded if it rolls back. On SQLite the store holds one connection of the pool for its statements, so give the pool room for the app too. MySQL 8's default sign-in over a connection without TLS needs sqlx's `mysql-rsa` feature, or TLS.

A store of your own implements `cronwatch::Store`: `init`, `upsert_job`, `get_job`, `list_jobs`, `delete_job`, `insert_run`, `update_run`, `get_run`, `list_runs`, `last_run`, `running_runs`, `get_state`, `set_state`, `prune` and `close`, with epoch milliseconds for every time; each returns a boxed future, so the trait is object safe without `async-trait`. Three provided methods default to `Unsupported` and are what keep processes sharing a store from judging a run twice or losing each other's updates: `update_run_if`, `compare_and_set_state` and `delete_run_if` (which takes back a queue attempt given back without failing; see [Rust schedulers](/docs/rust-schedulers/#retries)). They mean what the [TypeScript interface](/docs/stores/#writing-a-store) says. With the `storetest` feature, `cronwatch::storetest::run(|| store).await` runs the contract test the built-in stores pass.

## Alerts

With the `alerts` feature, `cronwatch::alerts` has the SDK's channels, each made from an options struct and returning an `Arc<dyn Channel>`, or an error when a key, address or URL is missing:

```rust
use cronwatch::alerts::{self, DiscordOptions, SlackOptions, WebhookOptions};
use cronwatch::{channel_fn, Alert, AlertType, Console};
use std::sync::Arc;

let cw = Client::builder()
    .store(store)
    .alert(alerts::slack(SlackOptions {
        webhook_url: std::env::var("SLACK_WEBHOOK_URL")?,
        link: Some(Arc::new(|a: &Alert| format!("https://app.example.com/cronwatch/jobs/{}", a.job))),
        ..Default::default()
    })?)
    .alert(alerts::discord(DiscordOptions { webhook_url: std::env::var("DISCORD_WEBHOOK_URL")?, ..Default::default() })?)
    .alert(alerts::webhook(WebhookOptions {
        url: "https://hooks.example.com/cronwatch".into(),
        secret: std::env::var("CRONWATCH_WEBHOOK_SECRET")?,
        ..Default::default()
    })?)
    .alert(channel_fn("pagerduty", |alert| async move {
        if alert.alert_type == AlertType::Recovered {
            return Ok(());
        }
        pagerduty::trigger(&alert.title, &alert.message).await
    }))
    .alert(Arc::new(Console))
    .build()?;
```

The first `alert` replaces the default console channel, and `alerts(vec![])` sends nothing. Every alert goes to every channel at once, each in a task of its own with 15 seconds to finish; a send past its time is dropped, which cancels it at its next await, and a channel that fails goes to the error handler (as `alert channel <name>`) and never holds up the others. A channel of your own implements `cronwatch::Channel` (`name()` and `send(&alert, &cx)`, returning a boxed future) or is a `channel_fn`; `cx.report_error(err)` reports a problem that did not stop it. A channel that does blocking I/O should do it in `spawn_blocking`.

### Email, SMS and error trackers

```rust
use cronwatch::alerts::*;

let email = EmailOptions { from: "CronWatch <alerts@example.com>".into(), to: vec!["ops@example.com".into()], ..Default::default() };

// Email. Each takes the EmailOptions.
alerts::resend(ResendOptions { api_key: env("RESEND_API_KEY"), email: email.clone(), ..Default::default() })?;
alerts::postmark(PostmarkOptions { server_token: env("POSTMARK_SERVER_TOKEN"), email: email.clone(), ..Default::default() })?;
alerts::sendgrid(SendgridOptions { api_key: env("SENDGRID_API_KEY"), email: email.clone(), ..Default::default() })?;
alerts::mailgun(MailgunOptions { api_key: env("MAILGUN_API_KEY"), domain: "mg.example.com".into(),
    region: "eu".into(), email: email.clone(), ..Default::default() })?;
alerts::ses(SesOptions { region: "us-east-1".into(), access_key_id: env("AWS_ACCESS_KEY_ID"),
    secret_access_key: env("AWS_SECRET_ACCESS_KEY"), email, ..Default::default() })?;

// SMS, one message per number, all at once. recovered: true texts recoveries too.
alerts::twilio(TwilioOptions { account_sid: env("TWILIO_ACCOUNT_SID"), auth_token: env("TWILIO_AUTH_TOKEN"),
    from: "+15005550006".into(), to: vec!["+15551110000".into()], ..Default::default() })?;

// Error trackers: one issue per job and alert type.
alerts::sentry(SentryOptions { dsn: env("SENTRY_DSN"), ..Default::default() })?;
alerts::honeybadger(HoneybadgerOptions { api_key: env("HONEYBADGER_API_KEY"), ..Default::default() })?;
alerts::datadog(DatadogOptions { api_key: env("DD_API_KEY"), site: "datadoghq.eu".into(),
    tags: vec!["env:prod".into()], ..Default::default() })?;
alerts::rollbar(RollbarOptions { access_token: env("ROLLBAR_ACCESS_TOKEN"), ..Default::default() })?;
alerts::bugsnag(BugsnagOptions { api_key: env("BUGSNAG_API_KEY"), ..Default::default() })?;
alerts::newrelic(NewRelicOptions { account_id: env("NEW_RELIC_ACCOUNT_ID"),
    api_key: env("NEW_RELIC_LICENSE_KEY"), ..Default::default() })?;
```

The options are the SDK's in Rust's case: `subject_prefix` and `link` in `EmailOptions`; `message_stream` (Postmark); `region` (`"eu"` for SendGrid, Mailgun and New Relic, the AWS region for SES); `session_token` and `configuration_set_name` (SES); `api_key_sid`, `api_key_secret`, `messaging_service_sid` and `segments` (Twilio, 1 to 10, `None` for the default of 3); `environment` (Sentry, Honeybadger and Rollbar, `"production"` by default); `release` (Sentry); `headers` (the webhook, extra request headers such as an `Authorization`); `endpoint` (Honeybadger, Bugsnag); `host` (Datadog); `release_stage` (Bugsnag); `event_type` (New Relic); and `recovered` and `link` wherever the SDK has them. `Default::default()` is always the SDK's default, so where the SDK sends recoveries unless told not to, Rust has the negative: `skip_recovered` for Sentry and Rollbar. No options struct prints its credentials with `{:?}`.

Each sends exactly the request the SDK's does: the same URL, headers and body, byte for byte (the crate's tests replay the SDK's recorded requests), with the same idempotency key, event id or UUID for one alert, so a provider that deduplicates drops a resend whichever language sent it. SES is signed with SigV4, with no AWS SDK. Each request has one ten second deadline for connecting, sending and reading the answer, reads at most 1 MiB of it, and follows no redirect, so credentials never reach another address. A refused request names only the URL's origin, never its path, with the channel's keys cut out. Every options struct takes a `transport`: `ReqwestTransport::with_client(client)` wraps a `reqwest::Client` of your own (a proxy, a custom root; build it with `redirect::Policy::none()`), or implement `Transport` for a test. The default transport honours `HTTP_PROXY` and `HTTPS_PROXY`, as reqwest does. [Alerts](/docs/alerts/#email-sms-and-error-trackers) describes what each one sends.

A webhook signs its body with `X-CronWatch-Signature: sha256=<hex>`. `alerts::signature(secret, body)` is that hex, for a receiver in Rust; compare it in constant time.

### Processes that cannot send

A job can run somewhere that cannot reach Slack or a mail relay: a sandboxed worker, a program without the app's secrets. Give that process `deliver(Deliver::AtCheck)`:

```rust
let recorder = Client::builder().store(store).deliver(cronwatch::Deliver::AtCheck).build()?;
```

It still records and evaluates every run, but queues each alert in the store instead of sending it. The next check in a process that sends normally delivers it, with triage if that process has it. Both processes must use the same store. See [processes that cannot send](/docs/alerts/#processes-that-cannot-send).

## pg_cron

pg_cron runs jobs inside Postgres, where nothing can wrap them. The pg_cron source (`cronwatch-sqlx` with the `pgcron` feature) reads what pg_cron records instead: on every check it reads `cron.job`, declares each job with its schedule, and copies new rows of `cron.job_run_details` in as runs, so a job that stops running is missed, a failed run alerts and a run that never ends is stuck.

```rust
use cronwatch_sqlx::{PgCron, PgCronOptions, SqlStore};
use std::sync::Arc;

let source = PgCron::new(pool.clone(), PgCronOptions { prefix: "db:".into(), ..Default::default() });
let cw = Client::builder().store(SqlStore::postgres(pool)).source(Arc::new(source)).build()?;
cw.start(Duration::from_secs(60));
```

It reads through a `sqlx::PgPool` on the database pg_cron runs in (its `cron.database_name`). Settings are read from `pg_settings`, so a setting the role may not read never fails the check. `PgCronOptions` has `jobs`, `job_ids` and `pick` to choose jobs, `prefix`, `job_name`, `options` and `options_for` (job options for every job, or per job; the schedule and zone always come from pg_cron) and `timezone` (by default the server's `cron.timezone`, else UTC). The rules for renamed jobs, runs cut off by a restart and history seen for the first time are the SDK's; see [Supabase and pg_cron](/docs/supabase/).

## Redaction

Before a run's output and error are stored, shown or sent anywhere, they are redacted. The default blanks values that look like secrets (secret-named pairs, credentials in URLs, authorization headers, private keys, JWTs, webhook URLs, and AWS, GitHub, Slack, Stripe, Google and API key formats), exactly what the SDK's default blanks: the patterns are the SDK's, run by an engine with JavaScript's semantics, so every case the SDK's tests hold gives the same bytes. An `expect` rule is checked before redaction, so it still sees what was logged. Redaction runs before the cap, so the cut never keeps the rest of a secret whose label it cut off.

```rust
Client::builder().no_redaction(); // keep output as logged
let card_number = regex::Regex::new(r"\b\d{4}(?:[ -]?\d{4}){3}\b")?;
Client::builder().redact(move |text| card_number.replace_all(&cronwatch::redact_secrets(text), "[card]").into_owned());
```

A function given to `redact` replaces the default; call `cronwatch::redact_secrets` inside it, as above, to keep the default patterns and add your own. One that panics is reported to the error handler and the default is used for that text.

## Triage

```rust
use cronwatch::triage::{self, AnthropicOptions};

let diagnose = triage::anthropic(AnthropicOptions {
    context: "A Rust service on Fly.io with a Postgres database.".into(),
    ..Default::default()
})?; // an error without ANTHROPIC_API_KEY
let cw = Client::builder().alert(slack).triage(diagnose).build()?;
```

`AnthropicOptions`, with the `triage` feature:

| Field | Default | |
|---|---|---|
| `model` | `"claude-opus-5"` | any current model id |
| `effort` | `"medium"` | `"low"`, `"medium"` or `"high"` |
| `max_tokens` | `None`, for 800 | a diagnosis is a paragraph |
| `context` | | a sentence about the app, so advice is specific |
| `no_fallbacks` | `false` | set it to stop routing a policy refusal to Anthropic's default fallback model inside the same request, if your account or gateway rejects the beta |
| `api_key` | `ANTHROPIC_API_KEY` | a missing key is an error from `anthropic` |
| `base_url` | `ANTHROPIC_BASE_URL`, else `https://api.anthropic.com` | |
| `transport` | reqwest on rustls | as for the channels |

There is no Anthropic crate to add: the Messages API is one POST, and it sends the request the SDK's official client sends. It runs only when an alert is sent (never per run, never for a recovery), once per alert, with one attempt and no retries. The client waits 25 seconds for it and the request gives up at 24, so the alert goes out without a diagnosis rather than late, and the failure is reported to the error handler. What is sent is in [AI triage](/docs/triage/). A triage of your own is `cronwatch::triage_fn(|cx| async move { .. })`, given the alert and the job's five newest runs, answering `""` for no diagnosis.

## API

`Client::builder()`:

| Method | Default | |
|---|---|---|
| `store(s)`, `store_arc(arc)` | in memory | a store |
| `alert(channel)`, `alerts(channels)` | the console | channels. `alerts(vec![])` sends nothing |
| `triage(t)` | | an `Arc<dyn Triage>` returning a diagnosis |
| `source(s)` | | where runs this process does not wrap come from, such as [pg_cron](#pg-cron). Each is synced at the start of every check; one that fails is reported and the check carries on |
| `cron_secret(s)`, `no_cron_secret()` | `$CRON_SECRET` | the bearer job handlers take and the dashboard's check endpoint accepts beside the token. `""` counts as unset |
| `retention(d)` | `"30d"` | how long finished runs are kept. Each job's newest run is always kept |
| `defaults(options)` | | `grace`, `timeout`, `timezone` and `failures_before_alert` for every job that does not set its own; `build` refuses any other option |
| `redact(f)`, `no_redaction()` | secret patterns | see [Redaction](#redaction) |
| `deliver(d)` | `Deliver::Now` | `Deliver::AtCheck` queues alerts for another process's check to send |
| `on_error(f)` | standard error | `Fn(&cronwatch::Error, &str)` for failures outside jobs: the store, a channel, triage |
| `clock(f)` | the system clock | a function returning epoch milliseconds; for tests |

`JobOptions::new()` takes `schedule` (five or six field cron, a nickname such as `"@hourly"`, or `"every 5m"`), `timezone` (IANA; the process's zone, from `$TZ` or `/etc/localtime`, by default), `grace` (`"10m"`), `timeout` (`"1h"`), `max_duration`, `budget(metric, ceiling)`, `expect(text)` (the output must contain it), `expect_match(m)` (a `regex::Regex` with the `regex` feature, or anything implementing `cronwatch::Matcher`; stored as `matches /source/`), `expect_fn(|output| bool)` (a panic in it fails the run), `failures_before_alert` (1), `description` and `tags`, with the rules in the [TypeScript API reference](/docs/api/). `cronwatch::describe_job(name, &options)` is the definition options give, without a client.

The client (every call that can reach the store is `async` and returns a `Result`):

| Method | |
|---|---|
| `job(name, options)` | declare a job and get its handle |
| `run(name, options, f)` | run without keeping a handle |
| `check()` | find missed and stuck runs, send alerts, retry alerts no channel accepted, prune |
| `start(every)`, `stop()` | check in a task; the interval is at least five seconds |
| `jobs()`, `jobs_with_runs(limit)`, `job_summary(name)` | summaries, without alerting |
| `runs(name, limit)`, `get_run(id)` | newest first; `limit` is 1 to 500 |
| `silence(name, d)`, `unsilence(name)` | stop alerts for a while; state keeps updating underneath. The silence ends on a whole millisecond, held at 2^53 - 1 ms however long it asks for |
| `forget(name)` | remove a job and its runs. A job still declared in code comes back: on its next run, or at the next check or dashboard read of a process that declares it |
| `resume_run(name, run_id)` | `resume` for a job declared in this process |
| `record_run(run, options)` | record a run that happened elsewhere, for a source; returns the alerts it sent. A metric that is not a finite number is an error and nothing is recorded |
| `sync_job(name)` | write a declaration to the store now, unless it already holds it |
| `routes(options)` | the dashboard and JSON API |
| `defined_jobs()` | the definitions declared in this process |
| `close()` | stop the check task, wait for a check already under way, then close the store |

Errors are `cronwatch::Error`: `Invalid` (an option, name, schedule or run id the SDK refuses, with its message), `Store` (the store's own error, kept as its source) and `Other`. Nothing panics for a bad option or a store failure. Rust errors carry no stack frames on stable, so a failed run's error has none; call `cronwatch::capture_panic_frames()` once at startup to keep a panic's backtrace with its run.

## Runs that span calls

A run is normally one call. Work that starts in one place and ends in another (a job that hands work to a queue, a webhook that reports completion later) can be one run too: `start` records it as running and returns a `RunHandle`, and `finish` on that handle, or on one from `resume` in another process, ends it.

```rust
use cronwatch::StartOptions;

let sync = cw.job("partner-sync", JobOptions::new().schedule("0 * * * *").timeout(Duration::from_secs(2 * 3600)))?;

let run = sync.start(StartOptions::new().id(&batch_id)).await?; // records a running run
// later, perhaps in another process
let run = sync.resume(&batch_id).await?; // or cw.resume_run("partner-sync", &batch_id)
run.log(format!("imported {count} rows"));
run.finish().await; // or run.fail(&err), or run.finish_with(result)
```

`StartOptions::id` takes your own stable id, 1 to 200 characters: a start with an id already recorded for this job records nothing and returns a handle on that run, and one recorded for another job is an error, as is an id starting `pgcron:`. A store that fails is reported to the error handler, never returned. The handle has `id()`, `job()`, `started_at()`, `log`, `metric`, `flush()` (append what is logged so far to the stored run), `finish`, `finish_with` and `fail`, and `is_active()`, false once it is finished. A run is judged once however many processes finish it: only the process whose conditional write lands evaluates it, and `finish` returns `None` when it recorded nothing. A handle dropped while active records nothing; a run that is never finished is marked stuck by the first check after the job's `timeout`, so set it to cover the whole span.

## Sharing a database with the other languages

The SQL store writes the same three tables as `@cronwatch/sdk/sqlite` and `@cronwatch/sdk/postgres`, the Ruby gem, and the Python, PHP, Go, Elixir, Java and .NET stores (the MySQL tables are the PHP and Go ports', which the Elixir, Java and .NET ports share): the same names, columns and indexes, epoch milliseconds in the time columns, and the same JSON in the JSON columns, byte for byte, keys in the SDK's order. The crate's tests share a SQLite file with the built SDK, and have a Node client and a Rust client take turns on one job's state. Create the tables from any side; the others find them and leave them alone. Use the same prefix everywhere.

Each process alerts on the jobs it runs, and any side's check sees every job in the store. One dashboard shows them all, and one MCP server reads it. Give each job a name only one side uses.

The public types write the SDK's JSON with `to_json()`, not serde_json, whose numbers and key order differ; with the `serde` feature they also serialize through that same JSON. The cron reader matches croner and the SDK, including the two [schedules that never make sense](/docs/schedules/#schedule-syntax): a date no month has never fires, and a one-time date is refused.

## Kept in step

The TypeScript SDK is the source of truth. Its build generates cases (duration parsing, schedules across daylight saving, sequences of runs and checks with the alerts and state they must produce, alert titles and messages, redaction, each channel's requests, stats and health) into `conformance/` in the repository, and the Rust tests replay every one, as the Ruby gem's and the Python, PHP, Go, Elixir, Java and .NET packages' do; the dashboard is checked against the SDK's pages byte for byte, straight, through tower and nested in axum. Cron parsing is also checked against croner itself on thousands of generated expressions. A change of behaviour lands in TypeScript first, the cases are regenerated, and the port is fixed until they pass. Where they disagree, the port is wrong: [open an issue](https://github.com/phillips-jon/cronwatch/issues).
