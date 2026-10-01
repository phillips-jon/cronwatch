# Changelog

Every notable change to CronWatch, newest first. All the packages, in every language, share one version, so each release is one section here, with a line per language where it matters. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and from 1.0 the versions follow [Semantic Versioning](https://semver.org) as the [Stability](https://cronwatch.dev/docs/stability/) page describes. The WordPress plugin, the Drupal module and the Craft CMS plugin keep their own changelogs too, for their stores.

## Unreleased

The preparation for 1.0: names settled across the languages, internals marked as internal, and the stored data, the JSON API and the webhook made ready to grow without breaking. Names that changed keep working under their old spelling, deprecated (see [Deprecations](https://cronwatch.dev/docs/deprecations/)); the breaking changes for 0.x users are listed first.

### Breaking changes for 0.x users

Every language:

- Processes sharing a store should all move to this release together: 1.x releases keep each other's stored data, 0.x releases do not.
- The dashboard API's silence and unsilence answer the job's summary, `{ ok: true, job }`, where they answered its stored state, `{ ok: true, state }`. `@cronwatch/mcp` reads either.
- `recordRun` refuses a run id longer than 200 characters, as the normal path already did.
- A blank `CRONWATCH_ENV` or `APP_ENV` (only spaces) counts as unset, and every language reads the environment the same way: `CRONWATCH_ENV`, then `APP_ENV`, then its own variable, trimmed and lowercased, with `prod` as production and `dev`, `local`, `test` and `testing` as development. This decides whether the dashboard makes a token of its own and whether a handler with no secret runs. See [Environment variables](https://cronwatch.dev/docs/environment/).
- Integrations record runs with their names spelled the one way: `active-job` (was `active_job`), `laravel-scheduler` and `laravel-queue` (were `schedule` and `queue`), `symfony-scheduler` and `symfony-messenger` (were `scheduler` and `messenger`), `drupal-cron` and `drupal-queue` (were `cron` and `queue`), `craft-queue` and `craft-command` (were `queue` and `command`), `spring-scheduled` (was `scheduled`) and .NET's `hosting` (was `schedule`). Runs recorded before keep their trigger; a filter on it should look for both spellings until they age out.
- A one-time date in place of a cron expression is refused when the job is declared, with the same message in every language, and a date no month has (`0 0 30 2 *`) is accepted and never fires.
- A dashboard token or cron secret of only whitespace, in `CRONWATCH_TOKEN`, `CRON_SECRET` or given in code, counts as unset, as the Environment variables page says: outside development the dashboard stays locked (503) and a handler answers 503 and reports why, where the blank value was taken as the token. A token or secret given in code that is neither a string nor null (`false`, a number) is refused with an error instead of becoming a password; PHP's deprecated `false` for "off" still works.
- The dashboard's sign-in form posts the token to `<base>/signin` in the request body, so it no longer lands in access logs as `?token=`. Opening a page with `?token=` still signs in, for the development sign-in link.

TypeScript:

- The environment is read from `CRONWATCH_ENV` and `APP_ENV` before `NODE_ENV`, which was the only one read. An app with `APP_ENV=development` set for another reason now counts as development.
- A one-time date, which croner accepted, is refused; a date no month has, which reported its job as unevaluable, never fires.

Ruby:

- The environment is read from `CRONWATCH_ENV` and `APP_ENV` before `Rails.env`, `RAILS_ENV` and `RACK_ENV`.
- The constants the docs do not name are private (`private_constant`), so referring to one raises `NameError`.
- A one-time date is refused; a date no month has, which Fugit refused, never fires.

Python:

- Every module declares `__all__`, so `from cronwatch.x import *` brings only the public names. The modules that only implement the client moved to underscored names (`cronwatch._evaluate` and the rest); the old names still work, with a `DeprecationWarning`.
- `local` and `testing` count as development.

PHP:

- `null` turns the cron secret, the dashboard's token and a handler's secret off, as in every other language. In 0.x `null` read `CRON_SECRET` or `CRONWATCH_TOKEN`, and `false` turned them off. Leaving the argument out still reads the environment, as does the new default, `Cronwatch\FromEnv::Read`; `false` still works, deprecated. Code that passed `null` on purpose to mean "read the environment" now turns the secret off. Laravel's and Symfony's settings are unchanged: an unset token or cron secret there is still read from the environment.

Rust:

- The data types (`Run`, `StoredJob`, `Alert`, `JobState`, `JobSummary` and the rest), `AlertDetails`'s variants and every options struct are `#[non_exhaustive]`, so a later release can add a field without a major. Build them with their constructors (`Run::new`, `StoredJob::new`, `Alert::new`, `AlertDetails::failure` and the others) and options with `new()` and a builder method per field (`SlackOptions::new().webhook_url(url)`), not struct literals.
- `js::parse` returns a `JsonError`; `ParseError` is a deprecated alias of it.

Java:

- These were public without being meant for apps, and are internal: `Json.quote`, `Json.kind`, `Json.copy` and `Json.MAX_DEPTH`; `PgCron.schedule`, `PgCron.jobName`, `PgCron.run`, `PgCron.HOLD_MS` and `PgCronRow`; `Twilio.MAX_SEGMENTS`; and in `dev.cronwatch.storetest` everything but `StoreContract.run`.
- A record that may grow (`Run`, `StoredJob`, `JobState`, `Alert`, `JobSummary`, `CheckResult`) is built with its static `of`; its canonical constructor is no longer promised.

.NET:

- `ICronwatchJob` moved from the `Cronwatch` namespace to `Cronwatch.Hosting`, with no alias: add `using Cronwatch.Hosting;` to a job class.
- The extension methods moved to Microsoft's namespaces: `AddCronwatch` and `AddCronwatchJob` to `Microsoft.Extensions.DependencyInjection`, `RunCronwatchCommandAsync` to `Microsoft.Extensions.Hosting`, and `MapCronwatch`, `UseCronwatch` and `MapCronwatchHandler` to `Microsoft.AspNetCore.Builder`. `services.AddCronwatch(...)` and `app.MapCronwatch(...)` compile as before, and the former classes keep the methods as plain static methods, deprecated.
- `TwilioOptions.Segments` is an `int?`, not a `double?`.
- A handler function whose lambda names its request's type must say `CronwatchRequest`.
- A store that implemented `IConditionalRunStore.UpdateRunIfAsync`, `IStateCasStore.CompareAndSetStateAsync` or `IRunDeletingStore.DeleteRunIfAsync` explicitly names the new interface instead, since the method now belongs to it.

Go and Elixir have no breaking changes beyond those every language shares.

### Added

- `GET /api` on every dashboard says what is answering: `{ ok: true, library, language, version, api: 1 }`. The API only grows within `api: 1`.
- The webhook's body starts with `"schema": 1`, and its JSON Schema is published at [cronwatch.dev/schemas/webhook/1.json](https://cronwatch.dev/schemas/webhook/1.json). A receiver can check the `X-CronWatch-Signature` header with `signature(secret, body)`, new in TypeScript (`@cronwatch/sdk/webhook`), Ruby (`Cronwatch::Alerts::Webhook.signature`), Python (`cronwatch.alerts.webhook.signature`) and PHP (`Webhook::signature`), as Go, Rust, Elixir, Java and .NET already had.
- Ruby: `client.routes(**options)`, the dashboard as a Rack app.
- Rust: constructors and builder methods for every data and options type.
- Java: a static `of` on each record that may grow.
- Drupal: Ultimate Cron's jobs are recorded, each on its own rules read as Ultimate Cron reads them (`drupal:<module>` for a module's `hook_cron`, `drupal:job:<id>` for any other, triggers `ultimate-cron` and `ultimate-cron-manual`), and every cron run is still `drupal:cron`. Before, the module left a site running Ultimate Cron alone.
- The [Stability](https://cronwatch.dev/docs/stability/), [Environment variables](https://cronwatch.dev/docs/environment/) and [Deprecations](https://cronwatch.dev/docs/deprecations/) pages.
- CI checks each package's public API: a committed report of it for TypeScript, Python and Elixir (`api.txt`), apidiff for the Go modules and cargo-semver-checks for the Rust crates, beside .NET's `PublicAPI.Unshipped.txt`.

### Changed

- The client's check loop is started with `startChecking(every)` (`start_checking` in Ruby, Python, Rust and Elixir, `StartChecking` in Go and .NET), since a job's `start()` opens a run. The client's `start(every)` still works, deprecated.
- `routes()` on the client is the one way to mount the dashboard. TypeScript's `createRoutes`, Ruby's and Python's `Web.new(client)` and `Web(client)`, and Java's `Routes.of` still work, deprecated.
- TypeScript: the client class is `Cronwatch`, with options `CronwatchOptions`, as every other language spells it; `CronWatch` and `CronWatchOptions` are deprecated aliases.
- Python: the triage class is `Anthropic` (was `AnthropicTriage`), and `Slack` and `Discord` take `webhook_url` by keyword.
- Ruby: `silence` takes the duration as `for:`, as the API and the MCP server do; `run(id)` without a block is `get_run(id)`.
- PHP: `$job->monitor($fn)` is the decorator (was `wrap`). Laravel's settings keys `store.prefix`, `store.create_tables`, `schedule.check` and `schedule.check_cron` are `table_prefix`, `create_tables`, `check.schedule` and `check.frequency`, as Symfony spells them; the old keys are still read, with a deprecation notice.
- Go: `PanicError` is gocron's panic type (was `Panic`), and `robfigcron.Converted` the one converted type. The `Watch` shortcuts are deprecated in favour of `New(cw, o).Option()`, and go in 2.0.
- Rust: axum and reqwest, both below 1.0, are leaving the core crate's API: `Routes::into_router()` and `ReqwestTransport::with_client` are deprecated and go in 1.0. Mount the tower service with `Router::new().nest_service(...)` instead.
- Java: `SqlStore` is in `dev.cronwatch.store`, beside `MemoryStore`, and the bridge is `SchedulerBridge`, as in .NET; the old names are deprecated.
- .NET: `CronwatchRequest` and `CronwatchResponse` (were `WebRequest` and `WebResponse`, whose names `System.Net` also has), `Adapters` (was `WebAdapters`), `SlackChannel.Webhook` and `DiscordChannel.Webhook` (were `Slack.Webhook` and `Discord.Webhook`), and the optional store interfaces named after their methods: `IUpdateRunIfStore`, `ICompareAndSetStateStore`, `IDeleteRunIfStore`.
- Public means documented. Each language marks the rest as internal in its own way (`@api private` in Ruby, underscored modules in Python, `@internal` in PHP, hidden from HexDocs in Elixir, internal or deprecated elsewhere). The scheduler bridges are for integration authors and outside the 1.x promise, and each store test kit promises only the entry point that runs the whole contract.
- `cronwatch-apalis` stays outside the 1.x promise while apalis 1.0 is a release candidate.

### Deprecated

Every deprecated name, with its replacement and the release it goes in, is on the [Deprecations](https://cronwatch.dev/docs/deprecations/) page. Renames of documented API keep working through 1.x and go in 2.0: the client's `start(every)` in every language; the dashboard's other constructors; TypeScript's `CronWatch` and `CronWatchOptions`; Python's `AnthropicTriage` and positional webhook URLs; PHP's `false` for "off" and `wrap`; Laravel's four old keys; Go's `Watch` shortcuts; Rust's `describe_job`; .NET's former type and interface names; Java's `jdbc.SqlStore` and `Bridge`. What was public by accident is deprecated now and goes in 1.0, in every language: `hmacSha256Hex` (`hmac_sha256_hex` in Python) wherever it was, the channels' and pg_cron's helpers and constants, Python's implementation modules' old names, .NET's `Json` helpers, and the store test kits' internals (Elixir's `StoreCase` helpers, .NET's `NewRun` and `ForeignRows`, Rust's `storetest` helpers). Rust's `Routes::into_router` and `ReqwestTransport::with_client` go in 1.0 too, since they hand out types of crates below 1.0.

### Fixed

- Ruby, Python and PHP keep the fields of a job's stored state and definition that they do not know, as the other languages did. A 0.x process in those languages erased what a newer release had written there (the queue of alerts being sent, for one) on its next write.
- Every language holds run ids to 200 characters on every path; `recordRun` let a longer one through, which the MySQL column could not hold.
- TypeScript: a schedule on a date no month has no longer runs out of stack.
- Craft CMS: `GET /cronwatch/api`, with no path after it, reaches the JSON API instead of the site's 404 page.
- One malformed job, run or state row (a hand edit, another writer, a damaged database) affects only its own job, in every language: it no longer stops every check or makes the whole dashboard answer 500. A definition that does not parse or is not an object reads as `{ name }`, and that job is reported and shown as failing; tags that are not a list of strings are left out; unparseable metrics read as `{}`; a time that is not a number reads as 0 (a start) or empty (a finish or duration); a state that does not parse reads as none and is replaced by the next write; and a queued alert that is not an object, a recovery that does not say what it recovers from, and an alert without a numeric time are dropped instead of blocking the job's alerts.
- An `Authorization` header that is not a bearer, such as a proxy's Basic auth, no longer locks the dashboard: the cookie and `?token=` sign in as if no header came.
- pg_cron: forgetting the old name of a renamed job while a run of it is open lets the run go, where every check after reported `job is not declared`.
- Elixir: `false` stays the way to turn a token or secret off, since `nil` means left out; a token, cron secret or handler secret of any other type was already refused, and the error now says so without printing the value.
- Elixir: a channel's, triage's or the instance's `transport:` options, which can hold a proxy's password, are left out when the struct is inspected (`IO.inspect`, a crash report).
- Elixir: the webhook body of a queued alert that carries a `schema` key of its own (another writer's) has one `schema` key, first, as the SDK writes it, where it had two and its signature differed.
- Elixir: `Cronwatch.Release.check/2` and `mix cronwatch.check` send alerts whatever the configuration's `deliver` says, so job nodes given `deliver: :check` have them sent; with `deliver: :check` they queued every alert and printed "sent". Called into a running instance that delivers at check time, the line says the alerts were queued, with a warning on standard error.

## 0.10.0 and earlier

Releases up to 0.10.0 (2026-09-30) are described in their [GitHub releases](https://github.com/phillips-jon/cronwatch/releases), and the plugins' in their own changelogs.
