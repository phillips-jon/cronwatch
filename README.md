# CronWatch

Cron and scheduled-job monitoring that lives inside your app. Wrap a job once; CronWatch records every run in a database you already have and tells you when a run is missed, fails, gets stuck, runs slow, goes over budget, or quietly does nothing. No server to run, no account to make. MIT.

**Site and docs:** [cronwatch.dev](https://cronwatch.dev)

```ts
// lib/cronwatch.ts
import { cronwatch } from "@cronwatch/sdk";
import { sqlite } from "@cronwatch/sdk/sqlite";
import { slack } from "@cronwatch/sdk/slack";

export const cw = cronwatch({
  store: sqlite({ path: "./data/cronwatch.db" }),
  alerts: [slack({ webhookUrl: process.env.SLACK_WEBHOOK_URL! })],
});

export const nightlyReport = cw.job("nightly-report", {
  schedule: "0 2 * * *", timezone: "UTC", grace: "15m", expect: "Report written",
});
```

```ts
// app/api/cron/nightly-report/route.ts: checks Authorization: Bearer CRON_SECRET
import { nightlyReport } from "@/lib/cronwatch";

export const GET = nightlyReport.handler(async (job) => {
  const report = await buildReport();
  job.log("Report written:", report.path);
  job.metric("cost", report.usdCost);
});
```

```ts
// app/cronwatch/[[...path]]/route.ts: a dashboard and JSON API behind CRONWATCH_TOKEN
import { cw } from "@/lib/cronwatch";

export const { GET, POST, DELETE } = cw.routes();
```

## Packages

| Package | What |
|---|---|
| [`@cronwatch/sdk`](packages/sdk) | the library for Node, Cloudflare Workers, Deno, and Bun: jobs, runs, checks, stores (memory, SQLite, Postgres, D1), pg_cron jobs read from Postgres, alerts (Slack, Discord, webhook, email, SMS, error trackers), dashboard and API, adapters for Node servers, optional Claude triage |
| [`cronwatch` gem](packages/ruby) | the Ruby port for Ruby and Rails apps: ActiveRecord store, ActiveJob and Sidekiq integration, schedules read from Solid Queue or sidekiq-cron, pg_cron jobs, the same alert channels, a check job, the dashboard as a Rack app. Same rules, alerts, and stored rows as the SDK |
| [`cronwatch-sdk` for Python](packages/python) | the Python port for Python apps: the memory, SQLite, and Postgres stores, the same alert channels and Claude triage, pg_cron jobs, the dashboard as a WSGI and ASGI app, Django, Celery and beat, APScheduler, async jobs, and `handler()` for platform crons and AWS Lambda |
| [`cronwatch/cronwatch` for PHP](packages/php) | the PHP port for PHP apps: the memory, SQLite, MySQL (and MariaDB), and Postgres stores, sharing tables with the SDK byte for byte, the same alert channels and Claude triage, pg_cron jobs, `vendor/bin/cronwatch check`, the dashboard (a bare script or PSR-15), `handler()` for platform crons, Laravel and Symfony integrations, a WordPress plugin, a Drupal module (`drupal/cronwatch`), and a Craft CMS plugin (`cronwatch/craft`) ([its DESIGN.md](packages/php/DESIGN.md)) |
| [`cronwatch.dev/go`](packages/go) | the Go port for Go apps: jobs, runs, and checks with `context` throughout and safe across goroutines, the memory store and a `database/sql` store for SQLite, Postgres, MySQL, and MariaDB over the app's own driver, sharing tables with the SDK byte for byte, the same alert channels and Claude triage, pg_cron jobs, the dashboard and `job.Handler` as `http.Handler`s, an AWS Lambda adapter, and modules of their own for robfig/cron, gocron, River, and Asynq ([its DESIGN.md](packages/go/DESIGN.md)) |
| [`cronwatch` crate](packages/rust) | the Rust port for Rust services, on tokio: jobs, runs, and checks, safe across tasks, the memory store and `cronwatch-sqlx` for SQLite, Postgres, MySQL, and MariaDB over the app's own sqlx pool, sharing tables with the SDK byte for byte, the same alert channels and Claude triage, pg_cron jobs, the dashboard and `handler()` framework-free with tower and axum adapters (and so AWS Lambda through `lambda_http`), a blocking client, and crates of their own for tokio-cron-scheduler and apalis ([its DESIGN.md](packages/rust/DESIGN.md)) |
| [`cronwatch` on Hex](packages/elixir) | the Elixir port for Elixir and Erlang services: an instance in the app's supervision tree, jobs run in the calling process and recorded when it dies, the memory store and an Ecto store for SQLite, Postgres, MySQL, and MariaDB over the app's own repo, sharing tables with the SDK byte for byte, the same alert channels and Claude triage over OTP's own sockets, pg_cron jobs, the dashboard and a job's handler as Plugs for a Phoenix router, telemetry events, a release's crontab check, and integrations for Oban and Quantum ([its DESIGN.md](packages/elixir/DESIGN.md)) |
| [`dev.cronwatch:cronwatch` for Java](packages/java) | the Java port for services on the JVM: jobs run in the calling thread and safe across platform and virtual threads, the current run carried across threads, a shutdown hook that records runs a stopping JVM leaves open, the memory store and a JDBC store for SQLite, Postgres, MySQL, and MariaDB over the app's own `DataSource`, sharing tables with the SDK byte for byte, the same alert channels and Claude triage over the JDK's own HTTP client, pg_cron jobs, the dashboard and a job's handler framework-free with adapters for the JDK's server, servlet containers (`cronwatch-servlet`), and Spring MVC and WebFlux, `CronwatchCli` for a crontab's check, a Spring Boot starter that watches every `@Scheduled` method (ShedLock included), and modules of their own for Quartz and JobRunr ([its DESIGN.md](packages/java/DESIGN.md)) |
| [`Cronwatch` on NuGet](packages/dotnet) | the .NET port for .NET services: jobs run in the caller's flow and safe across threads and tasks, the current run carried across awaits, a process-exit hook that records runs a stopping process leaves open, the memory store and an ADO.NET store for SQLite, Postgres, MySQL, and MariaDB over the app's own `DbDataSource`, sharing tables with the SDK byte for byte, the same alert channels and Claude triage over `HttpClient`, pg_cron jobs, the dashboard and a job's handler framework-free with an ASP.NET Core adapter (`Cronwatch.AspNetCore`), the client in the Generic Host with hosted jobs on a cron (`Cronwatch.Hosting`), `CronwatchCli` for a crontab's check, Native AOT support, and packages of their own for Hangfire and Quartz.NET ([its DESIGN.md](packages/dotnet/DESIGN.md)) |
| [`@cronwatch/mcp`](packages/mcp) | an MCP server so Claude Code, Cursor, and other agents can list jobs, read failures, run a check, and silence alerts |
| [`skills/cronwatch`](skills/cronwatch) | an agent skill for Claude Code, Codex, Cursor, and others: how to add monitoring to a job and how to investigate a failure. `npx skills add cronwatchdev/cronwatch` installs it ([on skills.sh](https://www.skills.sh/cronwatchdev/cronwatch)) |

## Installing

| Language | Install | Docs |
|---|---|---|
| TypeScript and Node | `npm install @cronwatch/sdk`, and the driver for a store (below) | [Getting started](https://cronwatch.dev/docs/) |
| Ruby and Rails | `bundle add cronwatch`, then `bin/rails generate cronwatch:install` and `bin/rails db:migrate` in a Rails app (Ruby 3.2 or newer; Rails 7.2, 8.0, and 8.1) | [Rails](https://cronwatch.dev/docs/rails/), [Ruby](https://cronwatch.dev/docs/ruby/), [its README](packages/ruby/README.md) |
| Python | `pip install cronwatch-sdk` | [Python](https://cronwatch.dev/docs/python/), [its README](packages/python/README.md) |
| PHP | `composer require cronwatch/cronwatch` | [PHP](https://cronwatch.dev/docs/php/), [its README](packages/php/README.md) |
| WordPress | [CronWatch in the plugin directory](https://wordpress.org/plugins/cronwatch/): search for it under Plugins, Add New Plugin, or `wp plugin install cronwatch --activate` | [WordPress](https://cronwatch.dev/docs/wordpress/) |
| Drupal | `composer require drupal/cronwatch`, then `drush pm:install cronwatch` | [Drupal](https://cronwatch.dev/docs/drupal/), [drupal.org](https://www.drupal.org/project/cronwatch) |
| Craft CMS | `composer require cronwatch/craft`, then `php craft plugin/install cronwatch`, or from the [Plugin Store](https://plugins.craftcms.com/cronwatch) | [Craft CMS](https://cronwatch.dev/docs/craft/) |
| Go | `go get cronwatch.dev/go`, and `go get cronwatch.dev/go/robfigcron` (or `/gocron`, `/river`, `/asynq`) for a scheduler | [Go](https://cronwatch.dev/docs/go/), [Go schedulers](https://cronwatch.dev/docs/go-schedulers/), [its README](packages/go/README.md) |
| Rust | `cargo add cronwatch --features alerts`, `cargo add cronwatch-sqlx --features postgres` (or `sqlite`, `mysql`), `cargo add sqlx --no-default-features --features runtime-tokio,postgres`, and `cargo add tokio --features macros,rt-multi-thread`; `cronwatch-tokio-cron-scheduler` or `cronwatch-apalis` for a scheduler | [Rust](https://cronwatch.dev/docs/rust/), [Rust schedulers](https://cronwatch.dev/docs/rust-schedulers/), [its README](packages/rust/README.md) |
| Elixir | `{:cronwatch, "~> 0.12"}` in `mix.exs`, with the app's Ecto adapter for the SQL store; Oban and Quantum are watched with no other package | [Elixir](https://cronwatch.dev/docs/elixir/), [Elixir schedulers](https://cronwatch.dev/docs/elixir-schedulers/), [its README](packages/elixir/README.md) |
| Java | `dev.cronwatch:cronwatch` (Java 21 or newer), or `dev.cronwatch:cronwatch-spring-boot-starter` in a Spring Boot app; `cronwatch-servlet`, `cronwatch-quartz`, and `cronwatch-jobrunr` beside it at the same version, with the app's JDBC driver for the SQL store | [Java](https://cronwatch.dev/docs/java/), [Java schedulers](https://cronwatch.dev/docs/java-schedulers/), [its README](packages/java/README.md) |
| .NET | `dotnet add package Cronwatch` (.NET 10 or newer), `Cronwatch.Hosting` in a Generic Host app or `Cronwatch.AspNetCore` in an ASP.NET Core app; `Cronwatch.Hangfire` and `Cronwatch.Quartz` beside it at the same version, with the app's ADO.NET driver for the SQL store | [.NET](https://cronwatch.dev/docs/dotnet/), [.NET schedulers](https://cronwatch.dev/docs/dotnet-schedulers/), [its README](packages/dotnet/README.md) |

The SDK depends only on `croner`. The core, the D1 store, the pg_cron source, and every alert channel use only `fetch` and Web Crypto, so they run on Node 22 or newer, Cloudflare Workers, Deno, and Bun; the SQLite and Postgres stores and `@cronwatch/sdk/node` need Node. Each driver is an optional peer, installed only when you use its entry point:

| Entry point | Install |
|---|---|
| `@cronwatch/sdk/sqlite` | `better-sqlite3` (and `@types/better-sqlite3` for TypeScript) |
| `@cronwatch/sdk/postgres` | `pg` (and `@types/pg` for TypeScript) |
| `@cronwatch/sdk/anthropic` | `@anthropic-ai/sdk` 0.115 up to (not including) 0.129 |
| `@cronwatch/sdk/pg-cron` | nothing: it queries through the `pg` Pool (or anything with `query()`) you pass it |
| `@cronwatch/sdk/d1`, `/node`, and the channels (`/slack`, `/discord`, `/webhook`, `/resend`, `/postmark`, `/sendgrid`, `/mailgun`, `/ses`, `/twilio`, `/sentry`, `/honeybadger`, `/datadog`, `/rollbar`, `/bugsnag`, `/newrelic`) | nothing |

The store entry points' type declarations refer to the driver's types, so a TypeScript project using them without `@types/better-sqlite3` or `@types/pg` fails with TS7016 unless `skipLibCheck` is on. The package ships ESM and CommonJS, each with its own types.

## One library, nine languages

Every language's package follows the same design: each writes the same tables and sends the same alerts, so a Rails app, a Go service, and a Node worker can share one database and one dashboard. All of them are tested against the same recorded cases, so a job behaves the same whichever language runs it. Each package's README and its page on [cronwatch.dev](https://cronwatch.dev/docs/) have the examples for its language and its schedulers.

## Stability

From 1.0 every package follows semantic versioning, one version for all of them. [Stability](https://cronwatch.dev/docs/stability/) says what a 1.x release promises (the documented API, the stored data, the JSON API, the webhook, settings and environment variable names, documented behaviour) and what it does not; [Environment variables](https://cronwatch.dev/docs/environment/) lists every variable each library reads; [Deprecations](https://cronwatch.dev/docs/deprecations/) lists every deprecated name with its replacement. What changed in each release is in [CHANGELOG.md](CHANGELOG.md).

## Why a library and not a service

A hosted monitor gives you an observer that is alive when your job is not. That is real, and it is the one thing a library cannot do: if your whole app is down, nothing inside it can alert (pair it with any uptime monitor for that case). Everything else, from a job that never fires to one that costs three times what it should, is caught from within, with your run history in your own database and nothing to sign up for.

## Contributing

Bugs, ideas, and questions are welcome in [the issue tracker](https://github.com/cronwatchdev/cronwatch/issues). [CONTRIBUTING.md](CONTRIBUTING.md) covers working on CronWatch itself: each language's tests, releases, and the site.

## License

MIT, see [LICENSE](LICENSE).
