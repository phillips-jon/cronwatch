---
title: Deprecations
description: Every deprecated name in every CronWatch library, with what to use instead and the release it goes in.
order: 14.5
group: Reference
---

# Deprecations

Every name that is deprecated today, in every language, with its replacement and the release it goes in. A deprecated name still works, and does what its replacement does, until then. How deprecation works is on the [Stability](/docs/stability/#deprecations) page.

Two kinds of name were deprecated in 0.11, while preparing 1.0, and they go at different times:

- **Renames of documented API** (a class, method, or option the docs showed, renamed so the names agree across languages) keep their old name as a deprecated alias through every 1.x release, and go in 2.0. So 1.0 breaks nothing the docs showed.
- **Names that were public by accident** (helpers, constants, the JSON and pg_cron helpers, the store test kits' internals) were deprecated in 0.11, still work, and go in 1.0 itself, as the [changelog](https://github.com/cronwatchdev/cronwatch/blob/main/CHANGELOG.md) will list.

Two Rust names go in 1.0 for a reason of their own: `Routes::into_router()` and `ReqwestTransport::with_client` hand out types of axum and reqwest, both below 1.0, which no 1.x promise could hold. A few internals were made internal outright, with no deprecation; they are [listed at the end](#hidden-in-0-11-without-a-deprecation).

## TypeScript

Marked `@deprecated`, so an editor strikes the name through. See [the API reference](/docs/api/#deprecated).

| Deprecated | Use instead | Goes in |
|---|---|---|
| `CronWatch`, `CronWatchOptions` | `Cronwatch`, `CronwatchOptions` | 2.0 |
| `createRoutes(cw, options)` | `cw.routes(options)` | 2.0 |
| `cw.start(every)` | `cw.startChecking(every)` | 2.0 |
| `hmacSha256Hex(secret, body)` from `/webhook` | `signature(secret, body)` | 1.0 |
| `MAX_SEGMENTS`, `MAX_BODY`, `smsSegments`, `smsBody` from `/twilio`; `parseDsn` from `/sentry`; `DESCRIPTION_MAX`, `embedDescription`, `codeBlockSafe`, `escapeMarkdown` from `/discord`; `PG_CRON_HOLD_MS`, `pgCronSchedule`, `pgCronJobName`, `pgCronRun` from `/pg-cron` | nothing: internal to their entry points | 1.0 |

`@cronwatch/mcp` has nothing deprecated.

## Ruby

Each warns in Ruby's deprecation category, shown under `ruby -w`, `-W:deprecated`, or `Warning[:deprecated] = true`, naming the line that called it. See [Ruby](/docs/ruby/#deprecated).

| Deprecated | Use instead | Goes in |
|---|---|---|
| `Cronwatch::Web.new(client, **options)` | `client.routes(**options)` | 2.0 |
| `client.start(every)` | `client.start_checking(every)` | 2.0 |
| `client.run(id)` without a block | `client.get_run(id)` | 2.0 |
| `client.silence(name, "2h")` | `client.silence(name, for: "2h")` | 2.0 |

## Python

Each warns with a `DeprecationWarning`. See [Python](/docs/python/#deprecated).

| Deprecated | Use instead | Goes in |
|---|---|---|
| `cw.start(every)`, `AsyncCronwatch.start(every)` | `start_checking(every)` | 2.0 |
| `cronwatch.web.Web(client, ...)` | `cw.routes(...)` | 2.0 |
| `AnthropicTriage` from `cronwatch.triage.anthropic` | `Anthropic` | 2.0 |
| `Slack(url)`, `Discord(url)` with the URL given positionally | `Slack(webhook_url=url)`, `Discord(webhook_url=url)` | 2.0 |
| `hmac_sha256_hex(secret, body)` from `cronwatch.alerts.webhook` | `signature(secret, body)` | 1.0 |
| the modules that only implement the client under their old names (`cronwatch.client`, `duration`, `stats`, `output`, `schedule`, `evaluate`, `format`, `serialize`, `job`, `run_handle`, `handler`, `alerts.email`, `alerts.sigv4`), and the helpers and constants of the public modules (`cronwatch.types.camel`, `cronwatch.alerts.twilio.sms_segments`, and the like) | the documented API: each module's `__all__` lists what it promises | 1.0 |

## PHP

Marked `@deprecated` in their docblocks; Laravel's renamed settings keys also raise an `E_USER_DEPRECATED` notice, once per process. See [PHP](/docs/php/#deprecated) and [Laravel](/docs/laravel/#settings).

| Deprecated | Use instead | Goes in |
|---|---|---|
| `cronSecret: false`, `token: false`, `handler($fn, secret: false)` | `null`, which turns them off as in every language | 2.0 |
| `$job->wrap($fn)` | `$job->monitor($fn)` | 2.0 |
| Laravel's `store.prefix`, `store.create_tables`, `schedule.check`, `schedule.check_cron` | `table_prefix`, `create_tables`, `check.schedule`, `check.frequency` | 2.0 |
| `Cronwatch\Alerts\Webhook::hmacSha256Hex($secret, $body)` | `Webhook::signature($secret, $body)` | 1.0 |
| `Twilio::MAX_SEGMENTS`, `MAX_BODY`, `smsSegments`, `smsBody`, `fits`, `segmentBudget`, `maskNumber`; `Sentry::parseDsn`; `Discord::DESCRIPTION_MAX`, `embedDescription`, `codeBlockSafe`, `escapeMarkdown`; `Sources\PgCron::HOLD_MS`, `BACKFILL`, `PAGE`, `MAX_PAGES`, the `*_SQL` constants, `schedule`, `jobName`, `run`, `epochMs`, `adapter` | nothing: internal to their channel or source | 1.0 |

The Symfony, WordPress, Drupal, and Craft CMS integrations have nothing deprecated.

## Go

Marked `Deprecated:` in their doc comments, which editors and `staticcheck` point at. See [Go](/docs/go/#deprecated).

| Deprecated | Use instead | Goes in |
|---|---|---|
| `cw.Start(every)` | `cw.StartChecking(every)` | 2.0 |
| `robfigcron.Watch(cw, o)`, `cwgocron.Watch(cw, o)` | `robfigcron.New(cw, o).Option()`, `cwgocron.New(cw, o).Option()` | 2.0 |
| `cwgocron.Converted` | `robfigcron.Converted` | 1.0 |
| `cwgocron.Panic` | `cwgocron.PanicError` | 1.0 |
| `JSValue()` on `Alert`, `CheckResult`, `Definition`, `JobState`, `JobSummary`, `Metrics`, and `Run` | `MarshalJSON`, or `encoding/json` | 1.0 |
| `cronwatch.Stderr`, `cronwatch.Stdout` | `WithErrorHandler`, and a channel of your own in place of `Console` | 1.0 |
| `cronwatch.MaxBody`, `cronwatch.ReservedRunIDPrefix` | nothing: internal | 1.0 |
| `pgcron.Hold`, `pgcron.Schedule`, `pgcron.JobName`, `pgcron.RunOf` | nothing: internal | 1.0 |
| `triage.System` | nothing: internal | 1.0 |
| everything in `storetest` but `Run` | `storetest.Run` | 1.0 |

## Rust

Marked `#[deprecated]`, so the compiler names the replacement. See [Rust](/docs/rust/#deprecated-and-what-changed-in-0-11).

| Deprecated | Use instead | Goes in |
|---|---|---|
| `Client::start(every)`, `blocking::Client::start(every)` | `start_checking(every)` | 2.0 |
| `Routes::into_router()` | `Router::new().nest_service("/cronwatch", routes)` | 1.0 |
| `ReqwestTransport::with_client(client)` | the default transport, or a `Transport` of your own | 1.0 |
| `describe_job(name, &options)` | nothing: documented before 1.0, so it stays through 1.x | 2.0 |
| `run_duration`, `state_version`, `js::ParseError`, `alerts::MAX_SEGMENTS`, `alerts::post::{TIMEOUT, MAX_BODY, origin}`, `triage::{SYSTEM, REQUEST_TIMEOUT, FALLBACK_BETA}`, `cronwatch_sqlx::pgcron::{HOLD, schedule, job_name, run_of}` | nothing: internal (`JsonError` for `ParseError`) | 1.0 |
| everything in `storetest` but `run` | `storetest::run` | 1.0 |

## Elixir

`start/0`, the `StoreCase` helpers, and the channels', pg_cron's, and triage's helpers are marked `@deprecated`, so the compiler warns; a keyword list given to `start/1` warns when it is called. See [Elixir](/docs/elixir/#deprecated).

| Deprecated | Use instead | Goes in |
|---|---|---|
| `Cronwatch.start()`, `Cronwatch.start(every: d)` | `Cronwatch.start_checking(every: d)` | 2.0 |
| `Cronwatch.StoreCase.contract/1`, `replay_fixture/2`, `make/1`, `scenarios/0`, `new_run/4`, `canonical/1` | `use Cronwatch.StoreCase, store: ..., fixture: ...` | 1.0 |
| `Alerts.Twilio.max_segments/0`, `sms_segments/1`, `sms_body/3`; `Alerts.Discord.embed_description/1`; `Alerts.Email.escape_html/1`; `Alerts.Webhook.body/1`; `Sources.PgCron.hold_ms/0`, `schedule/1`, `job_name/1`, `run_of/4`; `Triage.Anthropic.default_model/0`, `system/0` | nothing: internal | 1.0 |

## Java

Marked `@Deprecated(since = "0.11", forRemoval = true)`, so the compiler warns where each is used. See [Java](/docs/java/#deprecated).

| Deprecated | Use instead | Goes in |
|---|---|---|
| `cw.start()`, `start(Duration)`, `start(String)` | `cw.startChecking()`, with the same overloads | 2.0 |
| `dev.cronwatch.jdbc.SqlStore` | `dev.cronwatch.store.SqlStore` | 2.0 |
| `dev.cronwatch.bridge.Bridge` | `dev.cronwatch.bridge.SchedulerBridge` | 2.0 |
| `Routes.of(cw, options)` | `cw.routes(options)` | 2.0 |

## .NET

Marked `[Obsolete]`, so the compiler points at the replacement. See [.NET](/docs/dotnet/#deprecated).

| Deprecated | Use instead | Goes in |
|---|---|---|
| `cw.Start(every)` | `cw.StartChecking(every)` | 2.0 |
| `Cronwatch.Web.WebRequest`, `WebResponse` | `CronwatchRequest`, `CronwatchResponse` | 2.0 |
| `Cronwatch.Web.WebAdapters` | `Adapters` | 2.0 |
| `Cronwatch.Hosting.CronwatchServiceCollectionExtensions`, `Cronwatch.AspNetCore.CronwatchAspNetCore` | the same extension methods, in `Microsoft.Extensions.DependencyInjection` and `Microsoft.AspNetCore.Builder` | 2.0 |
| `Slack.Webhook(url)`, `Discord.Webhook(url)` | `SlackChannel.Webhook(url)`, `DiscordChannel.Webhook(url)` | 2.0 |
| `Json.Quote`, `Json.Kind`, `Json.Copy`, `Json.TryNumber`, `Json.MaxDepth` | `Json.Parse`, `Json.ParseObject`, `Json.Stringify` | 1.0 |
| `StoreContract.NewRun`, `ForeignRows` | `StoreContract.RunAsync`, `StoreReplay`, `FinishOnce` | 1.0 |
| `IConditionalRunStore`, `IStateCasStore`, `IRunDeletingStore` | `IUpdateRunIfStore`, `ICompareAndSetStateStore`, `IDeleteRunIfStore` | 2.0 |

The Hangfire and Quartz.NET packages have nothing deprecated.

## Hidden in 0.11 without a deprecation

A few internals that were public before 0.11 became internal in the same change, with no deprecated name left behind, because nothing documented used them:

- **Ruby**: the constants the docs do not name are `private_constant`, and the internal modules are marked `@api private`. See [Ruby](/docs/ruby/#public-and-internal).
- **Java**: `Json.quote`, `Json.kind`, `Json.copy`, `Json.MAX_DEPTH`; `PgCron.schedule`, `PgCron.jobName`, `PgCron.run`, `PgCron.HOLD_MS`, and `PgCronRow`; `Twilio.MAX_SEGMENTS`; and in `dev.cronwatch.storetest` everything but `StoreContract.run`.
- **Elixir**: the port's machinery, which the package itself calls from module to module (`Cronwatch.JS`, `JSRE`, `Cron`, `Zone`, `Duration`, `Schedule`, `Output`, `Serialize`, `Alerts.Post`, `Store.SQL`, and helpers such as `Alerts.Email.compose/2`, `Transport.check/2`, and `JobState.sending/2`), is hidden from HexDocs. It still works, since the package needs it public, but may change in any release.
- **PHP**: the classes and methods marked `@internal` (`Evaluate`, `Schedule`, `Format`, `Serialize`, `Output`, `Duration`, and the client's execution methods among them). They still work, since the package's own classes call them, but may change in any release.
