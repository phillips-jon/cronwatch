# CronWatch

Cron and scheduled-job monitoring that lives inside your app. Wrap a job once; CronWatch records every run in a database you already have and tells you when a run is missed, fails, gets stuck, runs slow or goes over budget. No server to run, no account to make. MIT.

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
| [`@cronwatch/sdk`](packages/sdk) | the library for Node, Cloudflare Workers, Deno and Bun: jobs, runs, checks, stores (memory, SQLite, Postgres, D1), pg_cron jobs read from Postgres, alerts (Slack, Discord, webhook, email, SMS, error trackers), dashboard and API, adapters for Node servers, optional Claude triage |
| [`cronwatch` gem](packages/ruby) | the Ruby port for Ruby and Rails apps: ActiveRecord store, ActiveJob and Sidekiq integration, schedules read from Solid Queue or sidekiq-cron, pg_cron jobs, the same alert channels, a check job, the dashboard as a Rack app. Same rules, alerts and stored rows as the SDK |
| [`cronwatch-sdk` for Python](packages/python) | the Python port for Python apps: the memory, SQLite and Postgres stores, the same alert channels and Claude triage, pg_cron jobs, the dashboard as a WSGI and ASGI app, Django, Celery and beat, APScheduler, async jobs, and `handler()` for platform crons and AWS Lambda |
| [`cronwatch/cronwatch` for PHP](packages/php) | the PHP port for PHP apps: the memory, SQLite, MySQL (and MariaDB) and Postgres stores, sharing tables with the SDK byte for byte, the same alert channels and Claude triage, pg_cron jobs, `vendor/bin/cronwatch check`, the dashboard (a bare script or PSR-15), `handler()` for platform crons, Laravel and Symfony integrations, a WordPress plugin, a Drupal module (`drupal/cronwatch`) and a Craft CMS plugin (`cronwatch/craft`) ([its DESIGN.md](packages/php/DESIGN.md)) |
| [`cronwatch.dev/go`](packages/go) | the Go port for Go apps: jobs, runs and checks with `context` throughout and safe across goroutines, the memory store and a `database/sql` store for SQLite, Postgres, MySQL and MariaDB over the app's own driver, sharing tables with the SDK byte for byte, the same alert channels and Claude triage, pg_cron jobs, the dashboard and `job.Handler` as `http.Handler`s, an AWS Lambda adapter, and modules of their own for robfig/cron, gocron, River and Asynq ([its DESIGN.md](packages/go/DESIGN.md)) |
| [`cronwatch` crate](packages/rust) | the Rust port for Rust services, on tokio: jobs, runs and checks, safe across tasks, the memory store and `cronwatch-sqlx` for SQLite, Postgres, MySQL and MariaDB over the app's own sqlx pool, sharing tables with the SDK byte for byte, the same alert channels and Claude triage, pg_cron jobs, the dashboard and `handler()` framework-free with tower and axum adapters (and so AWS Lambda through `lambda_http`), a blocking client, and crates of their own for tokio-cron-scheduler and apalis ([its DESIGN.md](packages/rust/DESIGN.md)) |
| [`cronwatch` on Hex](packages/elixir) | the Elixir port for Elixir and Erlang services: an instance in the app's supervision tree, jobs run in the calling process and recorded when it dies, the memory store and an Ecto store for SQLite, Postgres, MySQL and MariaDB over the app's own repo, sharing tables with the SDK byte for byte, the same alert channels and Claude triage over OTP's own sockets, pg_cron jobs, the dashboard and a job's handler as Plugs for a Phoenix router, telemetry events, a release's crontab check, and integrations for Oban and Quantum ([its DESIGN.md](packages/elixir/DESIGN.md)) |
| [`dev.cronwatch:cronwatch` for Java](packages/java) | the Java port for services on the JVM: jobs run in the calling thread and safe across platform and virtual threads, the current run carried across threads, a shutdown hook that records runs a stopping JVM leaves open, the memory store and a JDBC store for SQLite, Postgres, MySQL and MariaDB over the app's own `DataSource`, sharing tables with the SDK byte for byte, the same alert channels and Claude triage over the JDK's own HTTP client, pg_cron jobs, the dashboard and a job's handler framework-free with adapters for the JDK's server, servlet containers (`cronwatch-servlet`) and Spring MVC and WebFlux, `CronwatchCli` for a crontab's check, a Spring Boot starter that watches every `@Scheduled` method (ShedLock included), and modules of their own for Quartz and JobRunr ([its DESIGN.md](packages/java/DESIGN.md)) |
| [`Cronwatch` on NuGet](packages/dotnet) | the .NET port for .NET services: jobs run in the caller's flow and safe across threads and tasks, the current run carried across awaits, a process-exit hook that records runs a stopping process leaves open, the memory store and an ADO.NET store for SQLite, Postgres, MySQL and MariaDB over the app's own `DbDataSource`, sharing tables with the SDK byte for byte, the same alert channels and Claude triage over `HttpClient`, pg_cron jobs, the dashboard and a job's handler framework-free with an ASP.NET Core adapter (`Cronwatch.AspNetCore`), the client in the Generic Host with hosted jobs on a cron (`Cronwatch.Hosting`), `CronwatchCli` for a crontab's check, Native AOT support, and packages of their own for Hangfire and Quartz.NET ([its DESIGN.md](packages/dotnet/DESIGN.md)) |
| [`@cronwatch/mcp`](packages/mcp) | an MCP server so Claude Code, Cursor and other agents can list jobs, read failures, run a check and silence alerts |
| [`skills/cronwatch`](skills/cronwatch) | a Claude Code skill: how to add monitoring to a job and how to investigate a failure |
| [`site`](site) | cronwatch.dev, a static landing page and docs |

## Installing

| Language | Install | Docs |
|---|---|---|
| TypeScript and Node | `npm install @cronwatch/sdk`, and the driver for a store (below) | [Getting started](https://cronwatch.dev/docs/) |
| Ruby and Rails | `bundle add cronwatch`, then `bin/rails generate cronwatch:install` and `bin/rails db:migrate` in a Rails app (Ruby 3.2 or newer; Rails 7.2, 8.0 and 8.1) | [Rails](https://cronwatch.dev/docs/rails/), [Ruby](https://cronwatch.dev/docs/ruby/), [its README](packages/ruby/README.md) |
| Python | `pip install cronwatch-sdk` | [Python](https://cronwatch.dev/docs/python/), [its README](packages/python/README.md) |
| PHP | `composer require cronwatch/cronwatch` | [PHP](https://cronwatch.dev/docs/php/), [its README](packages/php/README.md) |
| WordPress | the plugin's zip, [cronwatch.zip](https://github.com/phillips-jon/cronwatch/releases/latest/download/cronwatch.zip): upload it under Plugins, Add New, or `wp plugin install https://github.com/phillips-jon/cronwatch/releases/latest/download/cronwatch.zip --activate` (it will be in the plugin directory once it is approved) | [WordPress](https://cronwatch.dev/docs/wordpress/) |
| Drupal | `composer require drupal/cronwatch`, then `drush pm:install cronwatch` (once its first release is on drupal.org) | [Drupal](https://cronwatch.dev/docs/drupal/) |
| Craft CMS | `composer require cronwatch/craft`, then `php craft plugin/install cronwatch`, or from the [Plugin Store](https://plugins.craftcms.com/cronwatch) | [Craft CMS](https://cronwatch.dev/docs/craft/) |
| Go | `go get cronwatch.dev/go`, and `go get cronwatch.dev/go/robfigcron` (or `/gocron`, `/river`, `/asynq`) for a scheduler | [Go](https://cronwatch.dev/docs/go/), [Go schedulers](https://cronwatch.dev/docs/go-schedulers/), [its README](packages/go/README.md) |
| Rust | `cargo add cronwatch --features alerts`, `cargo add cronwatch-sqlx --features postgres` (or `sqlite`, `mysql`), `cargo add sqlx --no-default-features --features runtime-tokio,postgres` and `cargo add tokio --features macros,rt-multi-thread`; `cronwatch-tokio-cron-scheduler` or `cronwatch-apalis` for a scheduler | [Rust](https://cronwatch.dev/docs/rust/), [Rust schedulers](https://cronwatch.dev/docs/rust-schedulers/), [its README](packages/rust/README.md) |
| Elixir | `{:cronwatch, "~> 0.8"}` in `mix.exs`, with the app's Ecto adapter for the SQL store; Oban and Quantum are watched with no other package | [Elixir](https://cronwatch.dev/docs/elixir/), [Elixir schedulers](https://cronwatch.dev/docs/elixir-schedulers/), [its README](packages/elixir/README.md) |
| Java | `dev.cronwatch:cronwatch` (Java 21 or newer), or `dev.cronwatch:cronwatch-spring-boot-starter` in a Spring Boot app; `cronwatch-servlet`, `cronwatch-quartz` and `cronwatch-jobrunr` beside it at the same version, with the app's JDBC driver for the SQL store | [Java](https://cronwatch.dev/docs/java/), [Java schedulers](https://cronwatch.dev/docs/java-schedulers/), [its README](packages/java/README.md) |
| .NET | `dotnet add package Cronwatch` (.NET 10 or newer), `Cronwatch.Hosting` in a Generic Host app or `Cronwatch.AspNetCore` in an ASP.NET Core app; `Cronwatch.Hangfire` and `Cronwatch.Quartz` beside it at the same version, with the app's ADO.NET driver for the SQL store | [.NET](https://cronwatch.dev/docs/dotnet/), [.NET schedulers](https://cronwatch.dev/docs/dotnet-schedulers/), [its README](packages/dotnet/README.md) |

The SDK depends only on `croner`. The core, the D1 store, the pg_cron source and every alert channel use only `fetch` and Web Crypto, so they run on Node 22 or newer, Cloudflare Workers, Deno and Bun; the SQLite and Postgres stores and `@cronwatch/sdk/node` need Node. Each driver is an optional peer, installed only when you use its entry point:

| Entry point | Install |
|---|---|
| `@cronwatch/sdk/sqlite` | `better-sqlite3` (and `@types/better-sqlite3` for TypeScript) |
| `@cronwatch/sdk/postgres` | `pg` (and `@types/pg` for TypeScript) |
| `@cronwatch/sdk/anthropic` | `@anthropic-ai/sdk` 0.115 or newer |
| `@cronwatch/sdk/pg-cron` | nothing: it queries through the `pg` Pool (or anything with `query()`) you pass it |
| `@cronwatch/sdk/d1`, `/node`, and the channels (`/slack`, `/discord`, `/webhook`, `/resend`, `/postmark`, `/sendgrid`, `/mailgun`, `/ses`, `/twilio`, `/sentry`, `/honeybadger`, `/datadog`, `/rollbar`, `/bugsnag`, `/newrelic`) | nothing |

The store entry points' type declarations refer to the driver's types, so a TypeScript project using them without `@types/better-sqlite3` or `@types/pg` fails with TS7016 unless `skipLibCheck` is on. The package ships ESM and CommonJS, each with its own types.

## One library, nine languages

Every port is a port of the SDK, not a new design: each writes the same tables and sends the same alerts, so a Rails app, a Go service and a Node worker can share one database and one dashboard. The TypeScript SDK is the source of truth: `npm run conformance` generates cases in `conformance/` that every port's tests replay, and a behaviour change lands in TypeScript first. Each package's README and its page on [cronwatch.dev](https://cronwatch.dev/docs/) have the examples for its language and its schedulers.

## Why a library and not a service

A hosted monitor gives you an observer that is alive when your job is not. That is real, and it is the one thing a library cannot do: if your whole app is down, nothing inside it can alert (pair it with any uptime monitor for that case). Everything else, from a job that never fires to one that costs three times what it should, is caught from within, with your run history in your own database and nothing to sign up for.

## Development

Develop on Node 24 (`.nvmrc`); CI also runs Node 22, the oldest supported (better-sqlite3 13 needs it). Postgres tests run when `CRONWATCH_TEST_PG` points at a database.

```bash
npm ci
npm run check          # dash check, typecheck, tests
npm run build          # every package and the site
npm run dev:site       # the site on http://localhost:4321, rebuilding on change
npm run dev:dashboard  # a dashboard of dummy jobs
npm run check:packages # pack both packages and use them from a scratch project (after build)
npm run conformance    # regenerate conformance/ from the SDK, for the Ruby gem and the Python, PHP, Go, Rust, Elixir, Java and .NET packages
```

The gem (Ruby 3.2 or newer), after `npm run build` so its Node compatibility tests can run:

```bash
cd packages/ruby
bundle install
bundle exec rake test
```

[Its README](packages/ruby/README.md#testing) has the rest: Postgres, each Rails series, the dashboard fixture and the MCP cross test.

The Python package (Python 3.11 or newer), with [uv](https://docs.astral.sh/uv/), after `npm run build` so its Node compatibility and croner parity tests can run:

```bash
npm run check:python                                 # uv run pytest in packages/python
cd packages/python && uv run --python 3.11 pytest    # a particular Python
```

It replays `conformance/` too, and is fixed the same way when the fixtures change. It is not part of `npm run check`, which does not need uv; CI runs it on Python 3.11 and 3.14.

The PHP package (PHP 8.2 or newer), with [Composer](https://getcomposer.org), after `npm run build` for the same reason:

```bash
npm run check:php                              # composer install and phpunit in packages/php
```

It replays `conformance/` as well. Its MySQL and MariaDB tests run when `CRONWATCH_TEST_MYSQL` and `CRONWATCH_TEST_MARIADB` are `mysql://` URLs ([its README](packages/php/README.md#testing) shows two throwaway servers); CI runs it on PHP 8.2 and 8.5, against both.

The Go module (Go 1.25 or newer), after `npm run build` for the same reason:

```bash
cd packages/go && go test -race ./...             # the core: standard library only
cd packages/go/sqltest && go test -race ./...     # the SQL store, in a module of its own that holds the drivers
cd packages/go/robfigcron && go test -race ./...  # and gocron, river, asynq and examples, each a module of its own
```

It replays `conformance/` too. The SQL store's Postgres, MySQL and MariaDB tests run when `CRONWATCH_TEST_PG`, `CRONWATCH_TEST_MYSQL` and `CRONWATCH_TEST_MARIADB` are set, River's when `CRONWATCH_TEST_PG` is, and Asynq's end-to-end test when `CRONWATCH_TEST_REDIS` names a Redis (`redis://127.0.0.1:6379/0`); each skips without them ([its README](packages/go/README.md#testing) has the formats). The scheduler modules require their schedulers at the oldest release they support. CI runs every module on Go 1.25 and 1.26 with the race detector, against all three databases and a Redis, and the scheduler modules again at their schedulers' newest releases.

The Rust workspace (Rust 1.85 or newer, 1.94 for `cronwatch-sqlx`), after `npm run build` for the same reason:

```bash
cd packages/rust && cargo test --workspace --all-features
```

It replays `conformance/` and the dashboard fixture too. The Postgres, MySQL, MariaDB and pg_cron tests run when `CRONWATCH_TEST_PG`, `CRONWATCH_TEST_MYSQL`, `CRONWATCH_TEST_MARIADB` and `CRONWATCH_TEST_PGCRON` are set ([its README](packages/rust/README.md#testing) has the rest), and `CRONWATCH_TEST_RUST=1 npm test --workspace packages/mcp` drives the MCP server against its dashboard. CI runs the core and `cronwatch-tokio-cron-scheduler` on Rust 1.85, `cronwatch-sqlx` and `cronwatch-apalis` on 1.94, and the whole workspace on stable, on Linux, macOS and Windows.

The Elixir package (Elixir 1.18 or newer on Erlang/OTP 27 or newer), after `npm run build` for the same reason:

```bash
cd packages/elixir && mix deps.get && mix test
```

It replays `conformance/` and the dashboard fixture too. The Postgres, MySQL, MariaDB and pg_cron tests run when `CRONWATCH_TEST_PG`, `CRONWATCH_TEST_MYSQL`, `CRONWATCH_TEST_MARIADB` and `CRONWATCH_TEST_PGCRON` are set ([its README](packages/elixir/README.md#testing-this-package) has the rest), and `CRONWATCH_TEST_ELIXIR=1 npm test --workspace packages/mcp` drives the MCP server against its dashboard.

The Java build (Java 21 or newer, with the Maven wrapper it commits), after `npm run build` for the same reason:

```bash
cd packages/java && ./mvnw -B verify
```

It replays `conformance/` too, compiling with Error Prone and `-Xlint:all` with warnings as errors; `./mvnw spotless:apply` formats the code ([its README](packages/java/README.md#testing-this-package) has the rest). CI runs it on JDK 21, 25 and the newest JDK, on Linux, macOS and Windows, and `CRONWATCH_TEST_JAVA=1 npm test --workspace packages/mcp` drives the MCP server against its dashboard.

The .NET solution (.NET 10 or newer, the SDK pinned by `global.json`), after `npm run build` for the same reason:

```bash
cd packages/dotnet && dotnet test
CRONWATCH_CULTURE=tr-TR dotnet test    # the suite again under the tr-TR culture, as CI runs it
```

It replays `conformance/` and the dashboard fixture too, with warnings as errors; `dotnet format` formats the code ([its README](packages/dotnet/README.md#testing-this-package) has the rest). CI runs it on .NET 10, on Linux, macOS and Windows, and `CRONWATCH_TEST_DOTNET=1 npm test --workspace packages/mcp` drives the MCP server against its dashboard.

`npm run check:dashes` fails on an em or en dash in any tracked text file; CI also checks the commit messages.

## Releasing

Every package shares one version: the SDK, the MCP server, the gem, the Python and PHP packages (the WordPress plugin with them, and the Drupal module and the Craft plugin requiring the library at it), the Go module and its scheduler modules, the Rust crates, the Elixir package, the Java build, the .NET solution, and the skill. From a clean `main`:

```bash
npm run release -- X.Y.Z --dry-run   # show every change and command, write nothing
npm run release -- X.Y.Z             # bump, regenerate, check, commit "Release X.Y.Z", tag vX.Y.Z
```

It bumps every file listed in `VERSIONED` at the top of `scripts/release.mjs` (and turns the WordPress readme's `= Unreleased =` changelog section into the release's, or adds a placeholder to rewrite), lists any other tracked file that still names the old version, refreshes `package-lock.json`, regenerates `conformance/` and the dashboard fixture, and runs `npm run check`, the build and `npm run check:packages`; then, when it finds what they need, the gem's tests and build, with a check of what the gem carries (Ruby 3.2 or newer; `--skip-ruby` skips them), the Python package's tests (uv; `--skip-python`) and the PHP package's (PHP 8.2 or newer and Composer; `--skip-php`). The Go, Rust, Elixir, Java and .NET tests are CI's. RubyGems spells a prerelease `X.Y.Z-beta.1` as `X.Y.Z.pre.beta.1` and refuses `+build` metadata, so the script does too.

It does not push or publish. It prints what to run next, in order:

- `git push origin main vX.Y.Z`. The tag starts the workflows that publish from it, and each first waits for CI's run on the tagged commit's push to `main` to pass (`ci-passed.yml`), publishing nothing if it fails, so push `main` with the tag: `pypi.yml` (PyPI, once `PYPI_ENABLED` is `true`), `php-split.yml` (the PHP package's own repository, which Packagist reads, once `PHP_SPLIT_ENABLED` is `true`), `php-plugins-split.yml` (the Drupal module's and the Craft plugin's repositories, once `DRUPAL_SPLIT_ENABLED` and `CRAFT_SPLIT_ENABLED` are; then make the drupal.org release from the tag), `crates.yml` (crates.io, once `CRATES_ENABLED` is `true`; the printed `cargo publish --workspace` line does it by hand), `hex.yml` (Hex and HexDocs, once `HEX_ENABLED` is `true`; the printed `mix hex.publish` line does it by hand), `nuget.yml` (nuget.org, once `NUGET_ENABLED` is `true`: it packs the five packages and pushes them when its reviewer approves; the printed `dotnet nuget push` line does it by hand), `java.yml` (Maven Central, once `MAVEN_ENABLED` is `true`, which it is not for the first release) and `wordpress-zip.yml`, which needs no switch: it builds the WordPress plugin's zip and attaches it to the tag's GitHub release, making the release with short notes if there is none yet (edit them after), as `cronwatch-X.Y.Z.zip` and as `cronwatch.zip`, the file `releases/latest/download/cronwatch.zip` serves and the docs link to.
- `npm publish` for the SDK and the MCP server, and `gem build` and `gem push` for the gem, once CI has passed on the release commit.
- `./mvnw -B -P release deploy` in `packages/java`, by hand for the first release and whenever `java.yml` is off, then a check of the validated deployment in the Central Publisher Portal before it is published.
- A tag and its push for the Go module (`packages/go/vX.Y.Z`) and for each scheduler module (`packages/go/robfigcron/vX.Y.Z` and the rest), then a `go list -m` that makes the Go proxy fetch them.
- `npm deprecate` lines for each `--deprecate <old>`.

A new package under `packages/` needs a row in both of the script's tables (`VERSIONED`, the file holding its version, and `PUBLISH`, how it ships), or the script refuses to run.

## Deploying the site

Once CI passes on a push to `main`, `.github/workflows/deploy.yml` runs the deploy script on the server, which builds a release on the server beside the live one and switches a symlink only when the build checks out. `deploy/README.md` has the server layout, the one-time setup and the rollback command.

## License

MIT, see [LICENSE](LICENSE).
