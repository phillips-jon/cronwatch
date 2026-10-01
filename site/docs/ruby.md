---
title: Ruby
description: The cronwatch gem in plain Ruby, its API, and sharing one database with Node, Python, PHP, Go, Rust, Elixir, Java and .NET.
order: 3.52
group: Ruby
---

# Ruby

The `cronwatch` gem is a port of `@cronwatch/sdk`, not a new design. It decides missed, failed, stuck, slow and over budget by the same rules, sends the same alert text, and writes the same rows, so a Ruby process can share one database with a Node, Python, PHP, Go, Rust, Elixir, Java or .NET process and the [MCP server](/docs/mcp/) works against any of them. For a Rails app, start with [Ruby on Rails](/docs/rails/); this page covers plain Ruby and the API underneath.

```ruby
# Gemfile
gem "cronwatch"
```

Ruby 3.2 or newer; the Rails integration is tested on Rails 7.2, 8.0 and 8.1. The only dependency is `fugit`, the cron parser Solid Queue and sidekiq-cron already bring. Everything else loads only when you require it:

| Require | For | Needs |
|---|---|---|
| `cronwatch` | the client, the memory store, and every alert channel: Slack, Discord, webhook, console, email, Twilio and the error trackers | |
| `cronwatch/pg_cron` | `Cronwatch::Sources::PgCron`, which reads pg_cron's jobs and runs through an ActiveRecord or pg connection | |
| `cronwatch/active_record` | the ActiveRecord store | `activerecord` |
| `cronwatch/rails` | the Railtie, `Cronwatch::ActiveJob`, `Cronwatch::CheckJob`, `Cronwatch::Web`, the `cronwatch:check` task, the install generator | `railties`, `activejob` |
| `cronwatch/sidekiq` | `Cronwatch::Sidekiq` for jobs that include `Sidekiq::Job`, its server middleware, `Cronwatch::Sidekiq::CheckWorker` | `sidekiq` 7 or newer |
| `cronwatch/scheduler` | schedules read from Solid Queue's `config/recurring.yml` or sidekiq-cron's schedule, and `Cronwatch.declare_from_scheduler!` | |
| `cronwatch/web` | the dashboard and JSON API as a Rack app | `rack` |
| `cronwatch/triage/anthropic` | Claude triage | `anthropic` |

In a Rails app, `require "cronwatch"` (which Bundler does for `gem "cronwatch"`) also loads `cronwatch/rails`, `cronwatch/web`, `cronwatch/scheduler`, and `cronwatch/sidekiq` when Sidekiq is in the bundle; the ActiveRecord store loads on first use. `cronwatch/triage/anthropic` is always required by hand, and so is `cronwatch/web` outside Rails. A missing gem raises a `LoadError` that names it. [Ruby on Rails](/docs/rails/) has the rest.

## Create one client

```ruby
require "cronwatch"

CW = Cronwatch.new(
  alerts: [Cronwatch::Alerts::Slack.new(webhook_url: ENV.fetch("SLACK_WEBHOOK_URL"))],
  retention: "30d",
)
```

Or configure one for the whole process and reach it anywhere as `Cronwatch.client`:

```ruby
Cronwatch.configure do |c|
  c.alerts = [Cronwatch::Alerts::Slack.new(webhook_url: ENV.fetch("SLACK_WEBHOOK_URL"))]
end
```

Configuring again replaces the client and stops the old one's interval. `Cronwatch.client` before any `configure` is a client with the defaults.

## Declare and run a job

```ruby
NIGHTLY = CW.job("nightly-report",
  schedule: "0 2 * * *", timezone: "UTC", grace: "15m", timeout: "30m",
  expect: "Report written", budget: { cost: 2 })

NIGHTLY.run do |job|
  path = build_report
  job.log("Report written:", path)
  job.metric(:cost, 1.2)
end
```

`run` returns what the block returns. What the block raises is recorded as the failure and raised again, so your own error handling still works. That includes exceptions outside `StandardError`: an `Interrupt`, `SystemExit`, `Sidekiq::Shutdown` or `Timeout` that stops the block is recorded as a failed run (`Interrupted: Sidekiq::Shutdown`) and raised again, so the run is never left running to be reported stuck later. Without keeping a handle, `CW.run("nightly-report") { |job| ... }` declares the job on first use; `CW.run(id)` without a block reads a run, and takes no options.

Logged output, a returned string and an error's message are stored as UTF-8: bytes that are not valid UTF-8 (binary output, a C extension's message) become the replacement character `�`, as they would in a JavaScript string.

Option names are snake_case (`max_duration`, `failures_before_alert`); conditions and alert types are symbols (`:missed`, `:over_budget`, `:recovered`). Durations are strings such as `"15m"` or `"1h30m"`, or milliseconds as an Integer. A duration string is at most 64 characters; a longer one raises `ArgumentError`. Anything that leaves the process (store rows, the JSON API, webhook bodies) uses the SDK's camelCase field names and string values.

## Run the check

A long-running process checks in a background thread:

```ruby
CW.start            # every minute; CW.start("5m") to change it
at_exit { CW.stop }
```

Calling `start` again while it runs does nothing; a different interval is reported to `on_error` and ignored, so call `stop` first to change it. The thread does not survive a fork: in a forking server (Puma with `preload_app!`, Unicorn), call `start` in each worker (`on_worker_boot`). A forked child gets fresh locks and no check in flight, so `start` and `check` work there.

Run one checker per store: one process with `start`, or one scheduled check, not one per process. Two checkers on one database can each send the same alert.

A script run from crontab exits when it is done, so nothing inside it notices the run that never happened. Add a second crontab line that checks:

```ruby
# bin/cronwatch-check
require_relative "../lib/jobs"   # declares every job, so a job that never ran is known

result = CW.check
puts "#{result.jobs.length} jobs, #{result.alerts.length} alerts"
CW.close
```

```
0 3 * * *    cd /srv/app && bundle exec ruby bin/nightly-backup
*/5 * * * *  cd /srv/app && bundle exec ruby bin/cronwatch-check
```

## Sidekiq without Rails

A Sidekiq app without Rails includes `Cronwatch::Sidekiq` in each job it watches, as a Rails app does (see [Sidekiq](/docs/rails/#sidekiq)), and adds the middleware to its server itself:

```ruby
require "cronwatch/sidekiq"

Cronwatch.configure do |c|
  c.store = Cronwatch::Stores::ActiveRecord.new   # or another store every process shares
end

Sidekiq.configure_server do |config|
  config.server_middleware { |chain| chain.add Cronwatch::Sidekiq::ServerMiddleware }
  config.on(:startup) { Cronwatch::Sidekiq.ready! }
end
```

`Cronwatch::Sidekiq.ready!` does what the Railtie does after boot: it declares every class that has called `cronwatch` (and what `Cronwatch.declare_from_scheduler!` asked for), and from then on a class declares itself as it loads. Call it once `Cronwatch.configure` has run and the job classes are loaded. Schedule `Cronwatch::Sidekiq::CheckWorker` every five minutes, with sidekiq-cron or anything else. With sidekiq-cron loaded, `schedule: :from_scheduler` reads its schedule file (`config/schedule.yml` unless its configuration names another) from the working directory; set `Cronwatch::Scheduler.sources` to read something else.

## The dashboard in any Rack app

```ruby
# config.ru
require "cronwatch/web"
require_relative "lib/jobs"

map "/cronwatch" do
  run Cronwatch::Web.new(CW)
end
```

Sinatra, Hanami and Roda mount it the same way. It serves the same pages and JSON API as the TypeScript routes, with the same token rules.

The board shows its counts by health, a timeline of the last day with a lane per job (a tick each time it was due, a mark for each run as long as it took, a dashed box for a missed slot) and the table of every job, and for each job its last seven days, runs and definition, all drawn on the server with no script. The environment is the first of `CRONWATCH_ENV`, `APP_ENV`, then `Rails.env` (when Rails is loaded), `RAILS_ENV` or `RACK_ENV` that holds more than spaces, trimmed and lowercased; `development`, `dev`, `local`, `test` and `testing` count as development and `production` and `prod` as production, as in every language (see [development](/docs/dashboard/#development)). Where the SDK reads `NODE_ENV` third, the gem reads the app's own.

It reads forms through Rack, so it works behind `Rack::MethodOverride` and with a request body that can be read only once. It is installable as a web app like the TypeScript dashboard, with its manifest, icons and service worker under the mount point (from `SCRIPT_NAME` or `base_path:`); see [Install it as an app](/docs/dashboard/#install-it-as-an-app).

`Cronwatch::Web.new(client = nil, token:, base_path:, origin:)`:

- `client`: the client to serve. Leave it out and each request uses `Cronwatch.client`.
- `token`: leave it out to read `CRONWATCH_TOKEN`; an empty string counts as unset. Without a token, while the environment (above) is development, the app makes a token of its own and prints a sign-in link to standard output on its first request (see below); anywhere else it answers 503. Puma, Unicorn, Thin and rackup set `RACK_ENV` to `development` when nothing names an environment, production included, so under one of them `RACK_ENV=development` alone does not count: `CRONWATCH_ENV`, `APP_ENV`, `Rails.env` or `RAILS_ENV` must say development (or `RACK_ENV` say `test`, `dev` or `local`). `nil` opts out and serves it open, for a mount behind your own auth.
- `base_path`: where it is mounted. It defaults to `SCRIPT_NAME`, which `map` and Rails' `mount` set, so it is only needed when something strips the prefix without setting it.
- `origin`: the public origin the dashboard is served from, such as `"https://app.example.com"`. Leave it out and each request's own origin is used, as Rack reads it (see below). Set it to pin the origin: it then replaces the request's for the cross-site check on writes, the sign-in cookie's `Secure` flag, the `Referer` the redirect back after a form follows, and the development sign-in line. It is read as the TypeScript routes read it (with `new URL`): whitespace around it is dropped, the host is lowercased, a host that is not ASCII becomes punycode (through the `simpleidn` gem, or Addressable when the app has it; without either, write it as `xn--...`), and it is reduced to scheme, host and port. Anything that is not an absolute `http` or `https` URL, or has a port outside 1 to 65535, raises `ArgumentError` when the app is made, and an empty string counts as unset.

### Signing in during development

The development token is 32 random bytes, base64url, made once per `Cronwatch::Web` instance, when it is built (in Rails, when the routes load), so a restart, or a reload that builds a new one, signs you out. The first request prints one line:

```text
[cronwatch] CRONWATCH_TOKEN is not set, so this development server made a token for the dashboard. Sign in: http://localhost:3000/cronwatch/?token=...
```

The link is built from `origin:` when it is set, and otherwise from that request's origin, and the mount path. A request's host is the client's to choose (`Host`, or `X-Forwarded-Host`, which Rack follows), so without `origin:` the host is printed only when it is loopback (`localhost`, a name ending in `.localhost`, `127.0.0.0/8` or `::1`); for any other host the line leaves it out, so a spoofed first request cannot point the link, token and all, somewhere else:

```text
[cronwatch] CRONWATCH_TOKEN is not set, so this development server made a token for the dashboard. Sign in: /cronwatch/?token=... on this server (the first request's host is not local, so the link leaves it out)
```

Open it once and the browser keeps a cookie, as with any token; scripts and the MCP server can send it as a bearer. Until then every request answers 401, and the page says the link is in the server log. Nothing about the request itself lets it in: a Rack app cannot tell a caller on this machine from one elsewhere (proxies, tunnels and a server bound to every interface all look alike), so the log, which only you can read, is the proof.

`/api/check` also accepts the client's `cron_secret` as a bearer. `GET /api` answers `{"ok":true,"library":"cronwatch","language":"ruby","version":"<the gem's version>","api":1}`, and a silence or unsilence over the API answers the job's summary (`{"ok":true,"job":{...}}`). See [Dashboard and API](/docs/dashboard/) for every endpoint, and [Ruby on Rails](/docs/rails/#mount-the-dashboard) for the details.

### Behind a proxy

The request's origin is what the cross-site check on writes (any method other than `GET` and `HEAD`) compares against. It comes from the host and scheme Rack reports (`Rack::Request#base_url`), which already follow `X-Forwarded-Host` and `X-Forwarded-Proto` the way Rails does, so the TypeScript routes' `trustProxy` has no counterpart here. The host is compared lowercased, as browsers send it.

- No proxy: nothing to set.
- One proxy: make sure it sends `X-Forwarded-Host` and `X-Forwarded-Proto` (or `Host`) with the public host and scheme, or pass `origin:` to pin it whatever a request says.
- More than one proxy: set `origin:`. Where a header lists several values, Rack takes the last (the hop nearest the app), not the public one the TypeScript routes' `trustProxy` reads first.

## Stores

`Cronwatch::Stores::Memory.new` is the default. Nothing survives a restart, so a miss cannot be noticed across one, and each process has its own. The client warns when it is used in production (the environment, read as above, is `production` or `prod`).

`Cronwatch::Stores::ActiveRecord.new(prefix: "cronwatch_", connection_class: nil)` writes through ActiveRecord, to Postgres or SQLite, in three tables named `cronwatch_jobs`, `cronwatch_runs` and `cronwatch_state`. `prefix` is lowercase letters, digits and underscores, not starting with a digit, at most 47 characters. `connection_class` is the ActiveRecord class whose database it uses (or its name, looked up on first use), `ActiveRecord::Base` by default; pass one that `connects_to` another database to keep the tables there. MySQL is not supported: the gem writes only the SDK's Postgres and SQLite statements, not the MySQL tables the PHP, Go and Rust ports use, and any adapter other than Postgres and SQLite is refused with `Cronwatch::Stores::ActiveRecord::UnsupportedAdapter`.

The store never creates its tables. In Rails, `bin/rails generate cronwatch:install` writes the migration that does. Elsewhere, create them once:

```ruby
require "cronwatch/active_record"

ActiveRecord::Base.establish_connection(ENV.fetch("DATABASE_URL"))
Cronwatch::Stores::ActiveRecord.create_tables!                    # or (connection, prefix: "ops_")

CW = Cronwatch.new(store: Cronwatch::Stores::ActiveRecord.new)
```

`create_tables!(connection = ActiveRecord::Base.connection, prefix: "cronwatch_")` runs the SDK's own `CREATE TABLE IF NOT EXISTS` statements (on Postgres under the same advisory lock the Node store takes), and `drop_tables!` takes the same arguments. If the tables are missing, the client's first use of the store raises `Cronwatch::Stores::ActiveRecord::MissingTables`, naming them and the command that creates them. A run still goes ahead and hands the error to `on_error`; `check` raises it. The client looks again on its next call.

Each store call checks a connection out for just that call, so runs and checks in other threads are fine, and it always uses the writing database, even inside `connected_to(role: :reading, prevent_writes: true)` (what Rails' automatic role switching wraps a `GET` in).

On Postgres the store never writes inside a transaction your code has open. It connects through a pool of its own (an abstract class under `Cronwatch::Stores::ActiveRecord`, with the writing database config of `connection_class`), so a job run inside `transaction do ... end` is recorded when it happens and stays recorded if the transaction rolls back, and a check running at the same time cannot deadlock with it. That pool is the size of the config's `pool` (5 by default), so each process may open up to that many more connections, one at a time as they are needed; count them against the database's connection limit, or give the store a `connection_class` whose config sets a smaller `pool`. SQLite allows one writer at a time, so there the store uses your pool: inside an open transaction each call runs in a savepoint, so a store error cannot abort the transaction, and the rows commit or roll back with it.

A store of your own is any object with the methods the memory store has: `upsert_job`, `get_job`, `list_jobs`, `delete_job`, `insert_run`, `update_run`, `update_run_if`, `get_run`, `list_runs`, `last_run`, `running_runs`, `get_state`, `set_state`, `compare_and_set_state`, `prune`, and optionally `init` and `close`. They mean what the [TypeScript interface](/docs/stores/#writing-a-store) says, with epoch milliseconds for every time. `insert_run` raises for an id it already holds, as a primary key would, rather than overwrite it.

`update_run_if(run, from_statuses)` writes a run's `status`, `finished_at`, `duration_ms`, `error`, `output` and `metrics` only when its stored status is one of `from_statuses`, in one step (`UPDATE ... WHERE id = ? AND status IN (...)`), and returns whether it wrote; an empty list or a missing run writes nothing and returns false. That is what lets exactly one of several processes finishing the same run judge it: the others see false and report the run as already finished. It is optional: without it the client reads the run and then writes it, which is safe only while one process at a time finishes a given run. The memory and ActiveRecord stores have it, the ActiveRecord store with the same SQL as the SDK's.

`compare_and_set_state(state, expected_version)` writes the state only when the stored one's `version` is `expected_version` (a missing row, or a state with no version, counts as 0) and returns whether it wrote. Every change to a job's state (a run starting or finishing, a check, a delivery, a silence) is read, worked out, and written with the version one higher through it; a refused write is worked out again from a fresh read, up to ten times, before it is reported to `on_error`. So two processes sharing a store, Ruby or Node, never lose each other's updates. It is optional: without it the client falls back to `set_state`, which is safe only while one process at a time updates a job's state. The memory and ActiveRecord stores have it; see [two processes, one store](/docs/stores/#two-processes-one-store).

## Alerts

```ruby
Cronwatch::Alerts::Slack.new(webhook_url: ENV.fetch("SLACK_WEBHOOK_URL"),
                             link: ->(alert) { "https://app.example.com/cronwatch/jobs/#{alert.job}" })
Cronwatch::Alerts::Discord.new(webhook_url: ENV.fetch("DISCORD_WEBHOOK_URL"))
Cronwatch::Alerts::Webhook.new(url: "https://hooks.example.com/cronwatch", secret: ENV["CRONWATCH_WEBHOOK_SECRET"])
Cronwatch::Alerts::Console.new

Cronwatch::Alerts::Custom.new("pagerduty") do |alert|
  next if alert.type == :recovered
  PagerDuty.trigger(summary: alert.title, details: alert.message)
end
```

They use only the standard library. Every alert goes to every channel at once; a channel that raises, or takes longer than 15 seconds, goes to `on_error` and never holds up the others.

A channel is any object with `name` and `call(alert, context)` that raises when the alert went nowhere. `context.on_error(error)` reports a problem that did not stop it going out (one of several recipients refusing it, say) to the client's `on_error`, as `"alert channel <name>"`. A channel whose `call` takes only the alert is called with the alert alone, and so is a `Custom` block with one parameter; give the block two (`do |alert, context|`) to get the context.

### Email, SMS and error trackers

The SDK's provider channels are here too, in the core gem and on the standard library alone (`Net::HTTP`, with OpenSSL signing the SES requests), so they need no gem of their own:

```ruby
# Email. Each takes from:, to: (one address or an array), subject_prefix: and link:.
Cronwatch::Alerts::Resend.new(api_key: ENV.fetch("RESEND_API_KEY"), from: "CronWatch <alerts@example.com>", to: "ops@example.com")
Cronwatch::Alerts::Postmark.new(server_token: ENV.fetch("POSTMARK_SERVER_TOKEN"), from: "alerts@example.com", to: "ops@example.com")
Cronwatch::Alerts::Sendgrid.new(api_key: ENV.fetch("SENDGRID_API_KEY"), from: "alerts@example.com", to: "ops@example.com")
Cronwatch::Alerts::Mailgun.new(api_key: ENV.fetch("MAILGUN_API_KEY"), domain: "mg.example.com", region: "eu",
                               from: "alerts@example.com", to: "ops@example.com")
Cronwatch::Alerts::Ses.new(region: "us-east-1", access_key_id: ENV.fetch("AWS_ACCESS_KEY_ID"),
                           secret_access_key: ENV.fetch("AWS_SECRET_ACCESS_KEY"), from: "alerts@example.com", to: "ops@example.com")

# SMS, one message per number, all at once. Recoveries are not texted unless recovered: true.
Cronwatch::Alerts::Twilio.new(account_sid: ENV.fetch("TWILIO_ACCOUNT_SID"), auth_token: ENV.fetch("TWILIO_AUTH_TOKEN"),
                              from: "+15005550006", to: ["+15551110000"])

# Error trackers: one issue per job and alert type.
Cronwatch::Alerts::Sentry.new(dsn: ENV.fetch("SENTRY_DSN"))
Cronwatch::Alerts::Honeybadger.new(api_key: ENV.fetch("HONEYBADGER_API_KEY"))
Cronwatch::Alerts::Datadog.new(api_key: ENV.fetch("DD_API_KEY"), site: "datadoghq.eu", tags: ["env:prod"])
Cronwatch::Alerts::Rollbar.new(access_token: ENV.fetch("ROLLBAR_ACCESS_TOKEN"))
Cronwatch::Alerts::Bugsnag.new(api_key: ENV.fetch("BUGSNAG_API_KEY"))
Cronwatch::Alerts::NewRelic.new(account_id: ENV.fetch("NEW_RELIC_ACCOUNT_ID"), api_key: ENV.fetch("NEW_RELIC_LICENSE_KEY"))
```

The options are the SDK's in snake_case: `subject_prefix`, `message_stream` (Postmark), `region` (`"eu"` for SendGrid, Mailgun and New Relic; the AWS region for SES), `session_token` and `configuration_set_name` (SES), `api_key_sid`, `api_key_secret`, `messaging_service_sid` and `segments` (Twilio), `environment` and `release` (Sentry), `endpoint` (Honeybadger, Bugsnag), `host` (Datadog), `release_stage` (Bugsnag), `event_type` (New Relic), and `recovered` and `link` wherever the SDK has them. A missing key, address or account raises `ArgumentError` when the channel is made. Keys, tokens, DSNs and AWS credentials are trimmed of the spaces and newlines a paste leaves around them first, so one that is only whitespace counts as missing. [Alerts](/docs/alerts/#email-sms-and-error-trackers) describes what each one sends.

Each sends exactly the request the SDK's does: the same URL, headers and body, byte for byte (the gem's tests replay the SDK's recorded requests), with the same idempotency key, event id or UUID for one alert, so a provider that deduplicates drops a resend whichever side sent it. Each request gives up 10 seconds after it starts, however slowly the answer arrives, and header values are sent with the whitespace around them trimmed, as `fetch` sends them (a webhook's own `headers:` values are trimmed too). A refused request raises `"<Provider> <origin> answered <status>: <start of the body>"`, and never the URL's path. The body is cut to 200 characters on a whole character, after the channel's keys are cut out of it (in case the provider echoes one), so no piece of a key survives at the cut. No channel follows a redirect: `Net::HTTP` never does, so a 3xx answer is refused like any other and the credentials go nowhere else. (The SDK asks `fetch` for the same; there the error reads as a failed fetch rather than `answered 307`.)

Twilio texts every number at once, each request in a thread of its own within the same 10 seconds. `segments` is 1 to 10 (3 by default, and for anything that is not a number), which keeps a message inside Twilio's 1600 character limit, and segments are counted as phones pack them: an extension character such as `{` or `€`, or an emoji, never straddles two. The alert counts as sent when any number took it, so the next check never texts the numbers that already have it again; each number that refused it is reported to `on_error` (as `"alert channel twilio"`, with all but its last four digits hidden). Only when every number refuses it is the alert a failure, kept and retried at the next check. Recoveries go to Sentry and Rollbar as info events and to Datadog and New Relic as events, but not to Twilio, Honeybadger or Bugsnag unless `recovered: true`. A webhook signs its body with `X-CronWatch-Signature: sha256=<hex>` as the SDK's does, and its body is the same JSON, starting with `"schema": 1` (its [JSON Schema](/schemas/webhook/1.json) is published). Verifying it in Ruby, with `Cronwatch::Alerts::Webhook.signature(secret, body)`, the HMAC-SHA256 as lowercase hex (every language has it under that name):

```ruby
expected = "sha256=#{Cronwatch::Alerts::Webhook.signature(secret, request.raw_post)}"
ok = Rack::Utils.secure_compare(expected, request.headers["X-CronWatch-Signature"].to_s)
```

Hash the raw body as it arrived, before parsing it. An alert has `type`, `job`, `definition`, `run`, `title`, `message`, `details`, `at` and `triage`. Parse the fields, not `title` and `message`, whose wording may change in any release. [Alerts](/docs/alerts/) describes each channel and the payload.

### Processes that cannot send

A job can run somewhere that cannot reach Slack or a mail relay: a sandboxed backup unit, a worker with no network, a script without the app's secrets. Give that process `deliver: :check`:

```ruby
RECORDER = Cronwatch.new(store: Cronwatch::Stores::ActiveRecord.new, deliver: :check)
```

It still records every run and evaluates it, but instead of sending an alert it queues it with the job's state. The next check in a process that sends normally (a `start` thread, `Cronwatch::CheckJob`, or whatever calls the check endpoint) delivers it, adds triage if that process has it, and marks it sent. Both processes must use the same store. Calling `start` in the recording process is allowed but sends nothing, so it warns once on standard error. See [processes that cannot send](/docs/alerts/#processes-that-cannot-send).

An alert no channel accepted waits in the same queue, and each check tries it once more. A queued alert that no longer describes the job is dropped instead of sent late: one whose condition has closed since, or closed and opened again, and a recovery once any condition it names is open again. One check spends at most 20 seconds of retries across all jobs, and whatever is left waits for the next check. More than twenty queued alerts for one job drops the oldest and says so through `on_error` (`"alert queue for <job>"`).

## pg_cron

pg_cron runs jobs inside Postgres, where nothing can wrap them. `Cronwatch::Sources::PgCron` reads what pg_cron records instead: on every check it reads `cron.job`, declares each job with its schedule, and copies new rows of `cron.job_run_details` in as runs, so a job that stops running is missed, a failed run alerts and a run that never ends is stuck. It needs no gem of its own; it queries through the connection you give it.

```ruby
require "cronwatch/pg_cron"

CW = Cronwatch.new(
  store: Cronwatch::Stores::ActiveRecord.new,
  sources: [Cronwatch::Sources::PgCron.new(PG.connect(ENV.fetch("DATABASE_URL")), prefix: "db:")],
)
CW.start
```

The first argument is an ActiveRecord class, connection pool or connection (queried with `exec_query`, a connection checked out for each query), a `PG::Connection` from the pg gem (`exec_params`), or anything with `query(sql, params)` that returns rows as hashes with string keys. The options:

| Option | Default | |
|---|---|---|
| `jobs` | every job the role can see | names or ids (`["nightly-vacuum", 7]`), or a callable given a `Cronwatch::Sources::PgCron::Job` (`jobid`, `jobname`, `schedule`, `database`, `username`, `active`) |
| `prefix` | `""` | put before every job name, and inside run ids, to keep them apart from your own |
| `job_name` | the jobname, cleaned | a callable giving the name for a Job; `pg_cron:<jobid>` for a job with no name |
| `options` | | `grace`, `timeout`, `max_duration`, `expect` (tested against pg_cron's return message, such as `"1 row"`), `failures_before_alert`, `description` and `tags`, as a hash or a callable given the Job. The schedule and timezone always come from pg_cron |
| `timezone` | `cron.timezone`, or UTC | the zone pg_cron reads its cron expressions in |

It reads the same tables with the same SQL as the SDK's `@cronwatch/sdk/pg-cron`, and maps them the same way: run ids `pgcron:<runid>`, trigger `pg_cron`, `$` for the last day of the month read as `L`, `N seconds` as `every Ns`, fields past the fifth dropped (pg_cron ignores them), a paused job declared without its schedule.

How runs are copied, case by case:

- A job seen for the first time: its twenty newest runs are copied quietly, and it is judged only from the newest finished one. After that it carries on from the newest run in the store, so a restart copies nothing twice.
- A run pg_cron has queued but not started: waited for, up to ten minutes, then copied as running from when it was first seen, so one that never starts is marked stuck. It never holds up the runs after it, which are read by their ids until it starts.
- A run a server restart cut off (`failed`, `server restarted`, with no `start_time`): a failure starting at its `end_time`, else at the job's newest run before it.
- A run a check marked stuck: still read, and when pg_cron finishes it the finish is recorded. A success closes stuck with a recovery; a failure is not counted twice.
- A job renamed, unscheduled or no longer picked by `jobs`: it keeps its old name's runs, and that name is declared again without a schedule, so it is never reported missed again (if it was missed, the check closes missed with a recovered alert saying it is no longer scheduled, `reason: :unscheduled`), its description saying why (`renamed to <new name>`, `no longer watched`, `no longer in cron.job`). Runs it had open are still finished under the old name. A process that starts after the change notices it too, once, from the job id in the stored description.
- A setting the role may not read: the settings come from `pg_settings`, which simply has no row for one, so a check inside the app's transaction never aborts it. `cron.timezone` is then taken as UTC and `cron.log_run` as on.

It warns once through `on_error` when it cannot read `cron.timezone`, when `cron.log_run` is off, and when `cron.job` shows no jobs (row level security shows a role only the jobs it scheduled). Roles, Supabase and purging are covered in [Supabase and pg_cron](/docs/supabase/).

A source of your own is any object with `name` and `sync(host)`. Each check calls `sync` first with the client as the host, whose `job`, `record_run`, `store`, `now` and `on_error(error, where)` it may use, and adds the alerts `sync` returns to its result.

`client.record_run(run, evaluate: true)` records a run that happened elsewhere, keyed by its id (1 to 200 characters, counted as JavaScript counts them, with no NUL; anything else raises `ArgumentError` and nothing is written): a new one is inserted, one stored as running (or marked stuck by a check) is finished once this one is not running, and anything else is left alone, so recording a run twice changes nothing. Finishing is a conditional write (`update_run_if`), so when two processes record the same finish only one judges it and the other reports it to `on_error` as already finished; a stored run of another job is left alone and reported (as `"recording <job>"`).

A finished run is judged as if it had been wrapped here (`expect`, failures, duration, budgets), its output and error redacted and capped the same way, and the alerts it sent are returned; one finishing after a check marked it stuck is judged only when it succeeded. `evaluate: false` stores it without judging it, for history. The job must be declared first, and a metric that is not a finite number raises `ArgumentError` before anything is written, as `job.metric` does.

## Redaction

Before a run's output and error are stored, shown or sent to a channel or triage, `redact` rewrites them. The default, `Cronwatch::Output.redact_secrets`, blanks values that look like secrets: `password=...`, `api_key: ...`, `:secret => "..."` and other secret-named pairs (quoted values in full), credentials in URLs, `Bearer`, `Basic` and `Token` authorization values, PEM private keys, JWTs, Slack and Discord webhook URLs, and AWS, GitHub, Slack, Stripe, Google and API key formats. It matches exactly what the SDK's default matches. An `expect` rule is checked before redaction, so it still sees what was logged. Redaction runs before the cap, so the cut never keeps the rest of a secret whose label it cut off. NUL characters are removed from output and errors, before the 16 KB cap and again after `redact`, because Postgres refuses them.

A `redact` that raises, or returns something other than a String, is reported to `on_error` (as `"redact"`) and the default patterns are used for that text, so the run is still recorded and nothing leaks.

```ruby
Cronwatch.new(redact: false)                                                     # keep output as logged
Cronwatch.new(redact: ->(text) { Cronwatch::Output.redact_secrets(text).gsub(/\d{16}/, "[card]") })
```

The patterns cannot catch everything; log less from jobs that handle secrets.

## Triage

```ruby
# Gemfile
gem "anthropic"
```

```ruby
require "cronwatch/triage/anthropic"

CW = Cronwatch.new(
  triage: Cronwatch::Triage::Anthropic.new(context: "A Sinatra app on Postgres, jobs run from crontab."),
)
```

`Cronwatch::Triage::Anthropic.new` takes:

| Option | Default | |
|---|---|---|
| `model` | `"claude-opus-5"` | any current model id |
| `effort` | `"medium"` | `"low"`, `"medium"` or `"high"` |
| `max_tokens` | `800` | a diagnosis is a paragraph |
| `context` | | a sentence about the app, so advice is specific |
| `fallbacks` | `true` | route a policy refusal to Anthropic's default fallback model inside the same request. Turn off if your account or gateway rejects the beta |
| `api_key` | what the `anthropic` gem resolves, normally `ANTHROPIC_API_KEY` | |
| `client` | | a configured `Anthropic::Client` to use instead |

It runs only when an alert is sent, never per run, and never for a recovery, and once per alert whatever happens to it. The client waits 25 seconds for it (on a retry, no longer than what is left of the check's 20 second retry budget), then sends the alert without a diagnosis and reports the timeout to `on_error`. When triage gives nothing (it raised, timed out or answered nil or an empty string) the alert's `triage` is nil, `null` in its JSON, and it is not asked again when the alert is retried; an alert that no channel accepted is queued with its diagnosis, so a retry sends the same one. The `anthropic` gem cannot cancel a request under way, so the request is made once, without retries, with a 24 second timeout, and ends on its own before the client stops waiting. A refusal gives no diagnosis. What is sent is in [AI triage](/docs/triage/).

A triage of your own is any callable that takes the context (`alert`, `recent_runs`, `signal`) and returns a string or nil. `signal.aborted?` turns true, and `signal.check!` raises, once the client has stopped waiting; nothing is interrupted, so honour it if the work can stop early.

## API

`Cronwatch.new(**options)` and `Cronwatch.configure`:

| Option | Default | |
|---|---|---|
| `store` | in memory | a store |
| `alerts` | console | an array of channels: objects with `call(alert, context)` (or `call(alert)`) and `name`. `[]` sends nothing |
| `triage` | | a callable returning a diagnosis |
| `cron_secret` | `ENV["CRON_SECRET"]` | the bearer `/api/check` on `Cronwatch::Web` accepts beside the token. Empty counts as unset; `nil` means none on purpose |
| `retention` | `"30d"` | how long finished runs are kept. Each job's newest run is always kept |
| `defaults` | | `grace`, `timeout`, `timezone`, `failures_before_alert` applied to every job that does not set its own |
| `redact` | secret patterns | a callable applied to output and errors before they are stored or sent; `false` keeps them as logged. One that raises or returns something other than a String is reported to `on_error` and the default is used. See [Redaction](#redaction) |
| `deliver` | `:now` | `:check` sends nothing from this process: alerts are queued in the store and the next check in a process that delivers now sends them, with triage. See [processes that cannot send](#processes-that-cannot-send) |
| `sources` | | where runs this process does not wrap come from, such as [pg_cron](#pg-cron). Each is synced at the start of every check; one that raises is reported to `on_error` (as `"source <name>"`) and the check carries on |
| `on_error` | `Rails.logger`, or a warning on standard error | `->(error, where) { ... }` for failures outside jobs: the store, a channel, triage |
| `now` | the system clock | a callable returning epoch milliseconds; for tests |

`client.job(name, **options)` takes `schedule`, `timezone`, `grace`, `timeout`, `max_duration`, `budget`, `expect` (a string, a Regexp or a callable; a Regexp that takes longer than one second to match counts as not matching, see [expect rules](/docs/conditions/#expect-rules)), `failures_before_alert`, `description` and `tags`, with the defaults and rules in the [API reference](/docs/api/). A name is 1 to 120 letters, digits, `.`, `_`, `:` or `-`. Bad options raise `ArgumentError` when the job is declared. It returns a handle whose `run(trigger: "run") { |job| ... }` runs the block, and whose `start` and `resume` handle a run that spans calls (see [Runs that span calls](#runs-that-span-calls)).

The block's `job` has `name`, `run_id`, `started_at`, `log(*parts)`, `metric(name, value)`, `metrics(hash)`, `signal`, and `aborted?`, true once the job's `timeout` has passed. Nothing is interrupted; a loop that can stop early checks it, or calls `job.signal.check!` to raise.

The client:

| Method | |
|---|---|
| `job(name, **options)` | declare a job and get its handle |
| `run(name, **options) { \|job\| ... }` | run without keeping a handle. Without a block, `run(id)` is `get_run(id)` |
| `check` | find missed and stuck runs, send alerts, retry alerts no channel accepted, prune. Returns a result with `checked_at`, `jobs`, `alerts` and `pruned`. Calls at the same time share one check. A job that cannot be evaluated is reported to `on_error` (as `"checking <job>"`) and listed as `failing`; the rest are checked as usual |
| `start(every = "1m")`, `stop` | check in a background thread; the first check comes after a second, and the interval is at least 5 seconds. A second `start` does nothing, and one with another interval is reported to `on_error`. With `deliver: :check`, `start` warns once that these checks send nothing |
| `jobs`, `jobs_with_runs(limit = 20)`, `job_summary(name)` | summaries, without alerting |
| `runs(name, limit = 50)`, `get_run(id)` | newest first; `limit` is 1 to 500 |
| `silence(name, for: "2h")`, `unsilence(name)` | stop alerts for a while; `silence(name, "2h")` works too, and any other keyword raises. State keeps updating underneath. The end is a whole millisecond, held at 2^53 - 1 however long the silence. Each returns the job's stored state, `version` included |
| `forget(name)` | remove a job and its runs. A job still declared in code comes back: on its next run, or at the next check or dashboard read of a process that declares it |
| `resume_run(name, run_id)` | `job(name).resume(run_id)` for a job declared in this process; raises `ArgumentError` for one that is not |
| `record_run(run, evaluate: true)` | record a run that happened elsewhere, for a source; see [pg_cron](#pg-cron). Returns the alerts it sent |
| `defined_jobs` | the definitions declared in this process |
| `close` | stop the interval, wait for a check already under way, then close the store |

## Runs that span calls

A run is normally one call to `run`. Work that starts in one place and ends in another (a job that hands work to a queue, a webhook that reports completion later) can be one run too: `start` records it as running and returns a run handle, and `finish` on that handle, or on one from `resume(run_id)` in another process, ends it.

```ruby
SYNC = CW.job("partner-sync", schedule: "0 * * * *", timeout: "2h")

run = SYNC.start(id: batch_id)      # records a running run
# later, perhaps in another process
run = SYNC.resume(batch_id)         # or CW.resume_run("partner-sync", batch_id)
run.log("imported", count, "rows")
run.finish                           # or run.fail(error)
```

`start(trigger: nil, id: nil)` records a running run and returns a handle. `trigger` defaults to `"start"`. `id` is your own stable id, 1 to 200 characters: a start with an id already recorded for this job records nothing and returns a handle on that run, and two starts with one id at once in a process record one run. A store that fails is reported to `on_error`, never raised, and the run is written when it finishes. `resume(run_id)` reads the run from the store; one that already finished, or is not there, gives a handle whose `finish` records nothing and reports why. Both raise `ArgumentError` only for an id that is not 1 to 200 characters, one starting with `pgcron:` (the [pg_cron reader's](#pg-cron) ids), or a run of another job; `start` raises that last whether the other job's start is still going or long done.

The handle:

| | |
|---|---|
| `id`, `job`, `started_at` | `started_at` is nil when a resumed run could not be read |
| `active?` | false once finished, and from the start when a resumed run has already finished or was not found |
| `log(*parts)`, `metric(name, value)`, `metrics(hash)` | as on the block's `job`; kept in the handle until `flush` or `finish` |
| `flush` | appends the lines and metrics so far to the stored run, which must still be running and belong to this job. Output is redacted as it is written. It reads, changes and writes the run's row, written only while it is still running, so when two processes append to one run at the same moment the last write wins, but a flush never undoes a finish. When the write fails, the lines stay in the handle for `finish`. The first 16 KB of everything flushed stay in the handle too, so `expect` at `finish` sees a line logged early, as `run` would, after the stored output has kept only the tail |
| `finish(outcome = nil)` | finishes the run and judges it like any other. `finish` or `finish(status: "ok")` is a success; `finish(error: e)` a failure, recorded like an error `run` caught; `finish("text")` or `finish(result: "text")` treats the value like the block's return (a string is the output when nothing was logged, and `expect` checks it). The handle's lines and metrics are added to those already stored (a later metric wins), then `expect`, redaction and the 16 KB cap apply. Returns the recorded run, or nil when nothing was recorded |
| `fail(error)` | `finish(error: error)` |

A run is judged once, however many times it is finished. The finish is written only while the stored run is still running (or marked stuck by a check), in one step (`update_run_if`), so when two processes finish the same run at once, one records and judges it and the other records nothing. A second `finish` on a handle, on a run another process has finished, or on a run of another job records nothing: it returns nil and is reported to `on_error` (as `"finishing <job>"`, `run <id> of <job> was already finished as ok; ignored`), never raised. When the store fails during `finish`, nothing is recorded, the error goes to `on_error`, and the handle stays active with its lines and metrics: call `finish` again once the store is back. An exception outside `StandardError` (`Interrupt`, a `Timeout`) raised meanwhile is raised again and leaves the handle open the same way. A run that is never finished is marked stuck by the first check after the job's `timeout`, so set `timeout` to cover the whole span; one finished after that follows the rule for a late `run`: a late failure is not counted again, and a late success closes stuck and recovers. For ActiveJob, see [Ruby on Rails](/docs/rails/#runs-that-span-jobs).

## Sharing a database with the other languages

A Rails app and a Node service can watch their jobs in one database. The Python, PHP, Go, Rust, Elixir, Java and .NET ports write the same tables too, so a process in any of them can join; this section describes the Node side, which the gem's tests run beside it. The ActiveRecord store writes the same three tables as `@cronwatch/sdk/postgres` and `@cronwatch/sdk/sqlite`: the same names, columns and indexes, epoch milliseconds in the time columns, and the same JSON in the JSON columns. The gem's tests run the SDK's own stores in Node beside it, on SQLite and Postgres, and check that each reads what the other wrote, that the tables are the same whoever creates them, and that the rows are the same bytes in every column. Create the tables from either side; the other side's `CREATE TABLE IF NOT EXISTS` finds them and leaves them alone. Use the same prefix on both sides.

Each process alerts on the jobs it runs, and either side's check sees every job in the store. One dashboard, Rails or Node, shows them all, and one MCP server reads it. Give each job a name only one side uses, and run one checker for the store, on one side.

The gem reads every schedule the SDK writes but a few cron forms croner takes and the gem does not:

- `W` in the day of the month (`0 0 15W * *`, the weekday nearest the 15th) and `LW`
- `#` on a range of weekdays (`0 0 * * 1-5#2`)
- a seventh (year) field
- `L` after a day of the month other than on its own (`0 0 3L * *`)

A job the Node side declares with one of these is shown on the Ruby dashboard as `failing` (or `silenced`, while it is) without a next expected time, and a Ruby check skips it and reports the schedule to `on_error`; the other jobs are checked as usual. Let the Node side check those jobs.

A date no month has (`0 0 30 2 *`) and a one-time date (`2026-12-01T00:00:00`) are read as every language reads them: see [Schedule syntax](/docs/schedules/#schedule-syntax).

Both sides write a job's state through `compare_and_set_state` and the same `version` inside its JSON, so a Ruby process and a Node process updating one job at the same moment refuse each other's stale writes rather than lose them.

A 1.x release keeps what it does not know. A field of a job's state or definition that a newer release wrote, a condition it opened, a run status or a trigger it recorded, is read, kept and written back unchanged by every write the gem makes, so any 1.x release of any language can share a store with any other, in either direction. Releases before 1.0 are not covered: upgrade every process that shares a store to 1.0 together.

## Kept in step

The TypeScript SDK is the source of truth. Its build generates cases (duration parsing, schedules across daylight saving, sequences of runs and checks with the alerts and state they must produce, alert titles and messages, stats and health) into `conformance/` in the repository, and the gem's tests replay every one. The dashboard is compared the same way: the gem's `Cronwatch::Web` must answer a fixed set of requests byte for byte as the SDK's routes do. A change of behaviour lands in TypeScript first, the cases are regenerated, and the gem is fixed until they pass. Where the two disagree, the gem is wrong: [open an issue](https://github.com/phillips-jon/cronwatch/issues).
