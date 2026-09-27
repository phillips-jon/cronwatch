# The Ruby port

`packages/ruby` is the `cronwatch` gem: the same library as `@cronwatch/sdk`, for Ruby and Rails apps. It is a port, not a new design. The TypeScript SDK is the source of truth for every behaviour, message and stored byte; when the two disagree, the Ruby side is wrong.

## Rules

- Ruby 3.2 or newer; Rails 7.2, 8.0 and 8.1. The only runtime dependency is `fugit` (the cron parser Solid Queue and sidekiq-cron already bring). Everything else is optional and loaded only from its own entry point, like the SDK's, each raising a `LoadError` that names the gem to add when it is missing:
  - `require "cronwatch"`: the client, the memory store, the Slack, Discord, webhook, console and custom channels, and the provider channels (Resend, Postmark, SendGrid, Mailgun, SES, Twilio, Sentry, Honeybadger, Datadog, Rollbar, Bugsnag, New Relic) (standard library only)
  - `require "cronwatch/pg_cron"`: `Cronwatch::Sources::PgCron`, the pg_cron reader. No gem of its own: it queries through what it is given, an ActiveRecord class, pool or connection (`exec_query`), a `PG::Connection` (`exec_params`), or anything with `query(sql, params)`
  - `require "cronwatch/active_record"`: the ActiveRecord store (needs `activerecord`)
  - `require "cronwatch/rails"`: the Railtie, `Cronwatch::ActiveJob`, `Cronwatch::CheckJob`, `Cronwatch::Web`, the `cronwatch:check` task and the install generator (needs `railties` and `activejob`; Rails brings `rack`)
  - `require "cronwatch/sidekiq"`: `Cronwatch::Sidekiq`, its server middleware and `Cronwatch::Sidekiq::CheckWorker` (needs `sidekiq` 7 or newer)
  - `require "cronwatch/scheduler"`: schedules read from Solid Queue's `config/recurring.yml` and sidekiq-cron's schedule (`schedule: :from_scheduler`, `Cronwatch.declare_from_scheduler!`); loaded by the Rails and Sidekiq entry points
  - `require "cronwatch/web"`: the Rack dashboard and JSON API (needs `rack`)
  - `require "cronwatch/triage/anthropic"`: Claude triage (needs the `anthropic` gem)
- In a Rails app `require "cronwatch"` (Bundler's) also loads `cronwatch/rails`, which loads `cronwatch/web`, `cronwatch/scheduler`, and `cronwatch/sidekiq` when Sidekiq is loaded; the ActiveRecord store autoloads on first use. No file requires another that requires it back, and `ruby -w` prints nothing from `lib`.
- Times are Integer epoch milliseconds everywhere, as in the SDK, so `evaluate` ports line for line and stored rows are identical.
- Ruby API names are snake_case (`failures_before_alert`, `max_duration`, `started_at`). Conditions and alert types are symbols (`:missed`, `:over_budget`, `:recovered`). Anything that leaves the process (store rows, JSON columns, the JSON API, webhook payloads) uses the SDK's exact camelCase field names and string values, so a Node process and a Ruby process can share one database and `@cronwatch/mcp` works against either.
- Alert titles and messages are the SDK's text, character for character.
- Every condition opens once and closes with a recovery. No repeat alerts.
- Text entering a run (logged output, a returned string, an error's message, a metric's name) is made valid UTF-8 first: bytes that are not UTF-8 become U+FFFD, as a JavaScript string would hold them.
- A job's block may raise anything. A `StandardError` is recorded as the failure and raised again by `JobHandle#run`; anything outside it (`Interrupt`, `SystemExit`, `Sidekiq::Shutdown`, a `Timeout`, `NotImplementedError`) is recorded as a failed run (`Interrupted: Sidekiq::Shutdown`) and raised again by `Client#execute` itself, so no run is left `running` to be reported stuck later.
- The environment is read in one place, `Cronwatch::Environment`: `Rails.env` when Rails is loaded, else `RAILS_ENV`, then `RACK_ENV` (the SDK reads `NODE_ENV`).
- A client survives a fork (Puma, Unicorn, Sidekiq): it notes its pid, and in a child it starts with fresh locks, no check in flight and no interval thread, so `start` and `check` work there.
- No em or en dashes anywhere, as in the rest of the repo.

## Layout

```
packages/ruby/
  cronwatch.gemspec  Gemfile  Rakefile  README.md  LICENSE  DESIGN.md
  lib/cronwatch.rb                 Cronwatch.new, Cronwatch.configure / Cronwatch.client, Configuration
  lib/cronwatch/
    version.rb      the gem's version
    js.rb           JavaScript's numbers, JSON.stringify, trim and UTF-16 lengths
    types.rb        Run, JobState, StoredJob, Alert, JobSummary, CheckResult, JobDefinition (Structs)
    duration.rb     "15m", "1h30m": parse and format
    stats.rb        percentiles
    output.rb       the output cap, error messages, UTF-8 scrubbing, secret redaction
    schedule.rb     Schedule: parse, due times, deadlines, covers (schedule.ts)
    zone.rb         Zone: IANA zones through TZInfo, croner's wall clock arithmetic
    cron_pattern.rb CronPattern: croner's reading of a cron expression
    walker.rb       CronPattern::Walker: croner's CronDate, the next match
    evaluate.rb     the alert rules, pure functions (evaluate.ts)
    format.rb       alert titles and messages
    serialize.rb    stored definitions, expect rules
    abort_signal.rb AbortSignal and AbortError, like JavaScript's AbortSignal
    job.rb          JobHandle (#run), JobContext (#log, #metric, #signal), RunRecorder
    http.rb         the channels' HTTP posts, constant time compare
    environment.rb  Environment: development?, production?
    flight.rb       Client::Flight, the check concurrent callers share
    ticker.rb       Client::Ticker, the interval thread start() runs
    client.rb       the client: job, run, check, start/stop, silence, unsilence, forget, jobs, job_summary, runs, close
    stores/memory.rb
    alerts/console.rb slack.rb discord.rb webhook.rb custom.rb
    alerts/provider.rb  what the provider channels share (alerts/shared.ts): the POST with redacted errors, alert ids, run summaries
    alerts/email.rb     subject, text and HTML for every email channel (alerts/email.ts)
    alerts/sigv4.rb     AWS Signature Version 4 on OpenSSL (alerts/sigv4.ts)
    alerts/resend.rb postmark.rb sendgrid.rb mailgun.rb ses.rb twilio.rb
    alerts/sentry.rb honeybadger.rb datadog.rb rollbar.rb bugsnag.rb newrelic.rb
    pg_cron.rb      Sources::PgCron and its ActiveRecord and PG::Connection adapters (sources/pgcron.ts)
    active_record.rb  stores/active_record.rb
    monitored.rb    what Cronwatch::ActiveJob and Cronwatch::Sidekiq share: the `cronwatch` macro, declarations
    scheduler.rb    schedules from Solid Queue and sidekiq-cron, converted and checked against Fugit
    sidekiq.rb      Cronwatch::Sidekiq, ServerMiddleware, CheckWorker
    web.rb  web/app.rb web/html.rb
    rails.rb  rails/railtie.rb rails/active_job.rb rails/check_job.rb rails/tasks.rb
    triage/anthropic.rb
  lib/generators/cronwatch/install/install_generator.rb
                    the migration and initializer templates, kept in the generator so the gem ships only Ruby
  test/             core tests; test/slow (the year-long schedule walk), test/active_record, test/rails.
                    test/pg_cron_test.rb and test/active_record/pg_cron_test.rb run against a real pg_cron when
                    CRONWATCH_TEST_PGCRON is set
```

## The Ruby API

```ruby
CW = Cronwatch.new(
  store: Cronwatch::Stores::ActiveRecord.new,          # default: Cronwatch::Stores::Memory.new
  alerts: [Cronwatch::Alerts::Slack.new(webhook_url: ENV.fetch("SLACK_WEBHOOK_URL"))],
  retention: "30d",
)

NIGHTLY = CW.job("nightly-report",
  schedule: "0 2 * * *", timezone: "UTC", grace: "15m", timeout: "30m",
  expect: "Report written", budget: { cost: 2 }, failures_before_alert: 1)

NIGHTLY.run do |job|
  job.log("Report written:", path)
  job.metric(:cost, 1.2)
end

CW.check          # finds missed and stuck runs, prunes, returns a CheckResult
CW.start          # a background thread that checks every minute (plain Ruby processes)
CW.silence("nightly-report", for: "2h")
```

`run(name) { ... }` declares and runs; `run(id)` without a block reads a run, and refuses options. `silence` takes a duration or `for:`, nothing else. A second `start` while one runs does nothing, and one with a different interval is reported to `on_error` and ignored (call `stop` first). `execute` and `report` are public for the integrations and marked `@api private`.

In Rails:

```ruby
# config/initializers/cronwatch.rb
Cronwatch.configure do |c|
  c.store  = Cronwatch::Stores::ActiveRecord.new
  c.alerts = [Cronwatch::Alerts::Slack.new(webhook_url: ENV["SLACK_WEBHOOK_URL"])]
end

class NightlyReportJob < ApplicationJob
  include Cronwatch::ActiveJob
  cronwatch schedule: "0 2 * * *", grace: "15m", expect: "Report written"   # name: "nightly-report"

  def perform
    cronwatch.log("Report written")
    cronwatch.metric(:cost, 1.2)
  end
end

# config/recurring.yml (Solid Queue) or sidekiq-cron: run Cronwatch::CheckJob every 5 minutes, once, not per process.
# config/routes.rb: mount Cronwatch::Web.new(Cronwatch.client) => "/cronwatch"
```

The job name defaults to the class name without `Job`, dasherized (`NightlyReportJob` is `nightly-report`). A job raising still raises after the run is recorded, so ActiveJob retries and error reporters see it as before.

## Delivery

`deliver: :now` (the default) sends each alert from the process that produced it. `deliver: :check` sends nothing: the alert is queued in the job's state (`undelivered`, at most `Client::MAX_UNDELIVERED`, the oldest dropped first) for the next check in a process that delivers now, which adds triage and sends it, as the SDK's `deliver: "check"` does. An alert no channel accepted is queued the same way and retried once per check, oldest first. A queued alert that no longer describes the job (`Evaluate.stale_alert?`) is dropped rather than sent; one check spends at most `Client::RETRY_BUDGET_MS` (20 seconds) retrying across all jobs; past `MAX_UNDELIVERED` the oldest are dropped and `on_error` hears of it. Triage is tried once per alert: `Alert#triage` nil with `triage_tried?` true is JSON `null`, never tried again.

Every read-modify-write of a job's state goes through `Client#update_state`: in turn with the process's other updates to the job, it reads the state, works out the next one, and writes it only when it changed, with `version` one higher, through the store's `compare_and_set_state` against the version read. A refused write is worked out again from a fresh read, up to `Client::STATE_ATTEMPTS` times. A store without `compare_and_set_state` gets `set_state`, as the SDK does.

Each channel sends in a thread of its own with a 15 second timeout, and triage gets 25 seconds. A channel (or triage) that times out is left to finish; until it has, nothing more is sent to it (the alert counts as not delivered there, and is retried) and no second triage starts, so a hung channel holds one thread rather than one per alert.

## Channels

Every channel is an object with `name` and `call(alert)` that raises on failure, and takes `http:` (anything with `post(url, body, headers)` returning `HTTP::Response`; `HTTP.default` is `Net::HTTP` with 10 second timeouts), which is how the tests replay requests without a network. The provider channels are the SDK's, request for request: the same URL, headers (lowercase names, in the SDK's order) and body, written with `JS.json` so the bytes are identical; the same stable alert id (the first 32 hex characters of SHA-256 of job, type and time) for idempotency keys, event ids and UUIDs; the same error text, `"<Provider> <origin> answered <status>: <first 200 UTF-16 units of the body>"` with every secret of four or more characters replaced by `[redacted]`; lengths, cuts and SMS segments counted in UTF-16 units and GSM-7 septets as JavaScript counts them; the same recovered defaults (sent by Sentry, Rollbar, Datadog, New Relic and the email channels; not by Twilio, Honeybadger or Bugsnag unless `recovered: true`). Constructor checks raise `ArgumentError` with the Ruby option names (`api_key`, not `apiKey`). The fixtures' `providerSends` and `providerFailures` replay all of it; SigV4 is also checked against the AWS test suite cases the SDK's tests use.

## Sources

`sources:` takes objects with `name` and `sync(host)`, as the SDK's `sources` does. `check` calls each, in order, after the store is ready and before anything else; one that raises is reported to `on_error` as `"source <name>"` and the check carries on, and the alerts a sync returns are added to the check's result. The host is the client: `job`, `record_run`, `store`, `now`, and `on_error(error, where)`.

`Client#record_run(run, evaluate: true)` is the SDK's `recordRun`: keyed by the run's id, a new run is inserted, a stored run still `running` is updated once this one is not, and anything else is left alone. Before that the output and error are made UTF-8, an `ok` run is checked against `expect`, and both are capped, redacted and cleared of NUL. A new run then goes through `on_run_start` and, once finished, `finish_run`; a stored running run that finished goes straight to `finish_run`. An insert that fails because another process inserted the run first returns nothing; any other failure raises. `evaluate: false` writes without judging. The job must be declared in this process, or it raises `ArgumentError`.

`Sources::PgCron` is `sources/pgcron.ts` line for line: the same SQL, the same mapping from rows to runs, the per-job cursor found from the store the first time (so a restart copies nothing twice), the first-sight import of the twenty newest runs judged only from the newest finished one, a not-yet-started run holding its job's cursor, `cron.log_run` off declaring jobs without schedules, and the one-time warnings for an unreadable `cron.timezone`, `log_run` off and an empty `cron.job` (row level security). Parameters that are arrays go to Postgres as array literals; timestamps come back as `Time` (ActiveRecord decodes them) or text (the pg gem), both read to the millisecond.

## Keeping the two in step

`conformance/` at the repo root holds JSON cases generated from the TypeScript build by `scripts/conformance.mjs`: duration parsing and formatting, schedule parsing and due/deadline/covers (including daylight saving), sequences of run and check events with the alerts and state they must produce, alert titles and messages, stats and health. The SDK's tests fail when the files are stale, and the gem's tests replay every case. A behaviour change lands in TypeScript first, the fixtures are regenerated, and the gem is fixed until they pass.

A stored schedule this port cannot read (croner forms such as `W`, `LW`, a range with `#`, a seventh field, or a date no month has, written by a Node process sharing the store) is reported to `on_error` and that job is skipped by the check; the others are checked, and it is listed as failing (`Evaluate.unevaluable_summary`) without a next expected time.

## Storage

The ActiveRecord store writes the same three tables as `packages/sdk/src/stores/sql.ts` (same names, `cronwatch_` prefix by default, same columns, same JSON in the JSON columns). The install generator creates them with a Rails migration (named for the prefix, so a second prefix gets its own); the store never creates tables itself in Rails. Postgres and SQLite are supported and tested; any other adapter is refused with `UnsupportedAdapter`.

On Postgres the store writes through a pool of its own: an abstract class under `Cronwatch::Stores::ActiveRecord`, connected with the `connection_class`'s writing database config. Its writes never join a transaction the app has open, so a run recorded inside one survives a rollback (and its alert, once sent, is not sent again), and a check waiting on a job's row cannot deadlock with a job holding that row inside the app's transaction. SQLite allows one writer at a time, so there the store uses the app's pool and joins its transaction in a savepoint. Every call runs on the writing role, even inside `connected_to(role: :reading, prevent_writes: true)`.

## Web

`Cronwatch::Web` is a Rack app with the SDK routes' URLs, JSON shapes, auth and headers: bearer or cookie token (`CRONWATCH_TOKEN`), `?token=` only on the HTML sign in, a token made per app and printed to stdout on the first request in development and test (`Cronwatch::Environment` instead of `NODE_ENV`), fail closed otherwise, the same CSRF and CSP rules, and `GET /api/check` with a bearer (the token or `CRON_SECRET`). Request bodies are read as the SDK's `request.json()` and `request.formData()` read them: forms through `Rack::Request#POST` (so a body `Rack::MethodOverride` already read still counts), JSON without a byte order mark and with bytes that are not UTF-8 as U+FFFD, every value as JavaScript's `String(value)`.
