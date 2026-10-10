---
title: Stability
description: What every 1.x release promises and what it does not, how deprecations and major releases work, and which language and framework versions are supported.
order: 14
group: Reference
---

# Stability

From 1.0, every CronWatch package follows [semantic versioning](https://semver.org), with one version number shared by every package in every language. A 1.x release, minor or patch, does not break anything this page promises. Anything that would is held for a major release (2.0), and gets a warning first. Releases before 1.0 promised nothing; 1.0 itself carries the changes that prepared for the promise, listed in [the changelog](https://github.com/cronwatchdev/cronwatch/blob/main/CHANGELOG.md).

## What 1.x promises

### The documented API

Public means documented. The API is the names in each package's README and on its pages here, with the signatures, options and defaults written there. Anything those leave out is internal, whatever the language would let you reach, and may change in any release. Each port marks its internals in its language's way: underscored modules and `__all__` in [Python](/docs/python/#deprecated), `@api private` and `private_constant` in [Ruby](/docs/ruby/#public-and-internal), `@internal` in [PHP](/docs/php/), modules and functions hidden from HexDocs in [Elixir](/docs/elixir/#what-1-x-promises).

A port keeps a new option or method additive: an existing call keeps compiling and meaning what it meant. Rust's data and options types are `#[non_exhaustive]` and Java's growing records are built with their static `of`, so a field can be added in a minor release; a store of your own builds them through those, as each page says.

### The stored data

Every port writes three tables, `cronwatch_jobs`, `cronwatch_runs` and `cronwatch_state` (the prefix is yours to change), with the same columns and the same JSON in them. For all of 1.x:

- No table or column is added, removed or changed. Anything new goes inside the JSON columns (a job's definition, a run's metrics, a job's state), which are made to grow.
- A release keeps what it reads but does not know: a field of a job's state or definition, a condition, a run status or a trigger that a newer release wrote is written back as it was, never erased or misread.
- So any 1.x release of any language can share one database with any other 1.x release, older or newer, as long as both have a store for that database (see [which languages can share which database](/docs/stores/#other-languages)).

0.x releases are not covered: upgrade every process that shares a store to 1.0 together.

### The JSON API

The dashboard's API keeps its paths and fields: `GET /api/jobs`, `GET /api/jobs/:name`, silence, unsilence, forget, the check and `GET /api/runs/:id`, as the [endpoint table](/docs/dashboard/#endpoints) lists them. `GET /api` says what is answering, with `api: 1` for this version of the API. Within it the API only grows: a release may add a field or an endpoint, but does not remove, rename or retype one. A change that is not additive comes with a new `api` number, in a major release. Read the fields you need and ignore the rest. [`@cronwatch/mcp`](/docs/mcp/) 1.x works with any 1.x dashboard, in any language.

### The webhook

The webhook's body has `"schema": 1` as its first field, then the alert: every field listed in [the alert payload](/docs/alerts/#the-alert-payload), the `details` of each alert type, the `X-CronWatch-Signature` header and its HMAC-SHA256. Its JSON Schema is at [/schemas/webhook/1.json](/schemas/webhook/1.json). Within `schema: 1` the payload only grows: a release may add a field, a `details` field, an alert type, a condition or a run status, so a receiver should ignore what it does not know. A change that is not additive comes with `"schema": 2`, in a major release.

### Configuration and environment variables

Option names and their defaults, every framework integration's settings keys (Laravel's and Symfony's config, Django's `CRONWATCH` setting, Spring Boot's `cronwatch.*` properties, .NET's `Cronwatch` section, the WordPress, Drupal and Craft settings) and every environment variable on the [Environment variables](/docs/environment/) page keep their names and meanings. A key that is renamed keeps being read under its old name, with a deprecation notice, until the next major (as Laravel's [four pre-1.0 keys](/docs/laravel/#settings) are).

### Documented behaviour

What the docs say a job does is promised:

- when a run counts as missed, failed, stuck, slow, over budget or under a floor, as [What it catches](/docs/conditions/) and [Schedules, grace and timeouts](/docs/schedules/) describe it, and the job options that set it (`grace`, `timeout`, `maxDuration`, `failuresBeforeAlert`, `budget`, `floor`, `expect` and the rest) with their defaults;
- one alert per condition: a condition opens once, alerts once, and closes with one recovery. There are no repeat reminders while it stays open. If reminders are ever added, they come as an option you turn on, in a minor release, and the default stays one alert;
- how schedules are read, including the two that never make sense (a one-time date is refused, a date no month has never fires);
- the stored spellings of triggers and tags, and the job names the integrations give, as [Triggers, tags and job names](/docs/dashboard/#triggers-tags-and-job-names) lists them.

## What it does not promise

- **The wording** of alert titles and messages, log lines and error messages, and how the channels other than the webhook lay out their messages. They are written for people and may read better in any release. Parse the webhook's fields, not the text.
- **The dashboard's pages**: their HTML, CSS and look. The JSON API is promised; the pages are not.
- **Triage**: the prompt sent to Claude and the default model.
- **Internal timing**: lease lengths, retry counts, the prune interval and the other constants that tune the library.
- **Anything internal**: everything the docs do not name.
- **The scheduler bridges**, the layer the scheduler integrations are built on (`cronwatch.dev/go/bridge` in Go, `cronwatch::bridge` in Rust, `Cronwatch.Bridge` in Elixir, `dev.cronwatch.bridge` in Java, `Cronwatch.Bridge` in .NET, and PHP's `Cronwatch\Bridge`, which is internal). They are public for integration authors, but change whenever an integration needs something, in any minor release. The integrations built on them are promised.
- **The store test kits' helpers.** Each kit promises the one entry point that runs the whole contract against a store of your own (Go's `storetest.Run`, Rust's `storetest::run`, Elixir's `use Cronwatch.StoreCase`, Java's `StoreContract.run`, .NET's `StoreContract.RunAsync`, with `StoreReplay` and `FinishOnce`), not the fixtures and helpers inside it. TypeScript's contract test is not shipped; copy it from the repository, as [Stores](/docs/stores/#two-processes-one-store) says.
- **The conformance fixtures** in the repository's `conformance/` directory, as files. They pin every port to the TypeScript SDK and are regenerated when, for example, alert wording improves; what they pin that matters is promised above.
- **Language and framework versions past their end of life**: see [support windows](#support-windows).

## Packages with a dependency below 1.0

A few packages expose types from a library that has not reached 1.0 itself, whose next minor release may break its API:

- `cronwatch-apalis` (Rust) is built on apalis 1.0's release candidates. It stays outside the 1.x promise until apalis 1.0 is final: a release of it may change its API to follow a new candidate.
- `cronwatch-sqlx` (Rust, sqlx 0.9), `cronwatch-tokio-cron-scheduler` (Rust, tokio-cron-scheduler 0.15), and the Go modules `cronwatch.dev/go/river` (River 0.x) and `cronwatch.dev/go/asynq` (Asynq 0.x) are in the promise, with one written exception: when their dependency's next breaking release forces a change to their API, it may land in a minor release of that one package, called out in the changelog. Everything else in them follows the rules above.
- The Elixir package reads Oban's crontab expressions through `Oban.Cron.Expression` and confirms zone names through `Tz.PeriodsProvider`, both of which their packages mark internal. A new release of Oban or tz may need a CronWatch patch release. CI tests each against its newest release, which is how such a break is caught.

## Deprecations

A name, option or settings key is deprecated in a minor release, never a patch:

1. It is marked in the language's own way (`@deprecated` in TypeScript and PHP, a warning in Ruby's deprecation category, a `DeprecationWarning` in Python, a `Deprecated:` comment in Go, `#[deprecated]` in Rust, `@deprecated` in Elixir, `@Deprecated` in Java, `[Obsolete]` in .NET), pointing at its replacement, with a Deprecated line in the changelog.
2. It keeps working until the next major release, and for at least six months.
3. A major release removes only what a release before it deprecated, so every removal has had a warning.

1.0 itself follows the same rule for what was deprecated before it. A rename of documented API keeps its old name, deprecated, through every 1.x release and goes in 2.0, so 1.0 breaks nothing the docs showed. A name that was public only by accident (a helper, a constant, a JSON or pg_cron helper, a store test kit's internals) is deprecated before 1.0 and goes in 1.0. So do Rust's two names that hand out types of crates below 1.0.

Every name deprecated today, in every language, is on the [Deprecations](/docs/deprecations/) page.

## Major releases

A breaking change waits for a major release. Majors are kept rare and coordinated: changes are deprecated in minors and their removals collected, then released together, at most about once a year. Because every package shares one version, a major is every package's 2.0, including those with no change of their own. Each major says what it removed, language by language, at the top of its notes. In Go, a major changes the module path (`cronwatch.dev/go/v2`), and every Composer, Cargo, Mix, Maven and NuGet constraint moves with it.

## Support windows

**Releases.** Within 1.x, fixes go into the newest minor release; older minors are not patched. Upgrading within 1.x is safe by the promise above. Once 2.0 ships, 1.x gets security fixes for six months more.

**Language and framework versions.** A supported version is dropped only in a minor release, never a patch, once its own maintainers have ended support for it, and the release before says so in its notes. Where a language's own habit is stricter, it is followed: Go modules support the two newest Go releases, as Go does; a Rust crate's minimum Rust may rise in a minor release, the core crate's never to a release newer than six months. Today's floors:

| Language | Language version | Frameworks |
|---|---|---|
| TypeScript and Node | Node 22 or newer | |
| [Ruby](/docs/ruby/) | Ruby 3.2 or newer | Rails 7.2, 8.0 and 8.1; Sidekiq 7 or newer |
| [Python](/docs/python/) | Python 3.11 or newer | Django 5.2, 6.0 and 6.1; Celery 5.5 or newer; APScheduler 3.10 or newer, below 4 |
| [PHP](/docs/php/) | PHP 8.2 or newer | Laravel 12 and 13; Symfony 6.4, 7.4 and 8.1; WordPress 6.1 or newer; Drupal 10.3 and 11; Craft CMS 5.3 or newer |
| [Go](/docs/go/) | Go 1.25 or newer | robfig/cron v3, gocron v2, River and Asynq at the versions on [Go schedulers](/docs/go-schedulers/) |
| [Rust](/docs/rust/) | Rust 1.85 or newer (1.94 for `cronwatch-sqlx`) | tokio-cron-scheduler 0.15 |
| [Elixir](/docs/elixir/) | Elixir 1.18 on OTP 27 or newer | Oban 2.20 or newer; Quantum 3.5 |
| [Java](/docs/java/) | Java 21 or newer | Spring Boot 3.5 and 4; ShedLock 6.10 and 7; Quartz 2.5; JobRunr 8 |
| [.NET](/docs/dotnet/) | .NET 10 or newer | Hangfire 1.8.0 or newer; Quartz.NET 4.0.0 or newer |

## How the promise is checked

Each package's public API is checked on every push, so a change to it cannot land unnoticed. The TypeScript, Python and Elixir packages keep a report of their API in the repository (`api.txt`) that a test compares with the code, and .NET keeps its surface in `PublicAPI.Unshipped.txt`, which the build checks: an addition is a line of the diff, and a removal stands out. The Go modules are compared with their last release by apidiff, and the Rust crates by cargo-semver-checks, which fail on an incompatible change. The other ports' APIs are reviewed by hand at each release.
