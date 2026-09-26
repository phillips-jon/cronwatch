---
title: Ruby
description: The cronwatch gem in plain Ruby, its API, and sharing one database with a Node app.
order: 3.2
---

# Ruby

The `cronwatch` gem is a port of `@cronwatch/sdk`, not a new design. It decides missed, failed, stuck, slow and over budget by the same rules, sends the same alert text, and writes the same rows, so a Ruby process and a Node process can share one database and the [MCP server](/docs/mcp/) works against either. For a Rails app, start with [Ruby on Rails](/docs/rails/); this page covers plain Ruby and the API underneath.

```ruby
# Gemfile
gem "cronwatch"
```

Ruby 3.2 or newer; the Rails integration is tested on Rails 7.2, 8.0 and 8.1. The only dependency is `fugit`, the cron parser Solid Queue and sidekiq-cron already bring. Everything else loads only when you require it:

| Require | For | Needs |
|---|---|---|
| `cronwatch` | the client, the memory store, and the Slack, Discord, webhook and console channels | |
| `cronwatch/active_record` | the ActiveRecord store | `activerecord` |
| `cronwatch/rails` | the Railtie, `Cronwatch::ActiveJob`, `Cronwatch::CheckJob`, the `cronwatch:check` task, the install generator | `railties`, `activejob` |
| `cronwatch/web` | the dashboard and JSON API as a Rack app | `rack` |
| `cronwatch/triage/anthropic` | Claude triage | `anthropic` |

In a Rails app, `require "cronwatch"` (which Bundler does for `gem "cronwatch"`) also loads `cronwatch/rails`, and the ActiveRecord store loads on first use. `cronwatch/web` and `cronwatch/triage/anthropic` are always required by hand. [Ruby on Rails](/docs/rails/) has the rest.

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

`run` returns what the block returns. What the block raises is recorded as the failure and raised again, so your own error handling still works. Without keeping a handle, `CW.run("nightly-report") { |job| ... }` declares the job on first use.

Option names are snake_case (`max_duration`, `failures_before_alert`); conditions and alert types are symbols (`:missed`, `:over_budget`, `:recovered`). Durations are strings such as `"15m"` or `"1h30m"`, or milliseconds as an Integer. Anything that leaves the process (store rows, the JSON API, webhook bodies) uses the SDK's camelCase field names and string values.

## Run the check

A long-running process checks in a background thread:

```ruby
CW.start            # every minute; CW.start("5m") to change it
at_exit { CW.stop }
```

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

## The dashboard in any Rack app

```ruby
# config.ru
require "cronwatch/web"
require_relative "lib/jobs"

map "/cronwatch" do
  run Cronwatch::Web.new(CW)
end
```

Sinatra, Hanami and Roda mount it the same way. It serves the same pages and JSON API as the TypeScript routes, with the same token rules, reading `RAILS_ENV` or `RACK_ENV` where the SDK reads `NODE_ENV`.

`Cronwatch::Web.new(client = nil, token:, base_path:)`:

- `client`: the client to serve. Leave it out and each request uses `Cronwatch.client`.
- `token`: leave it out to read `CRONWATCH_TOKEN`; an empty string counts as unset. Without a token the app answers only `localhost` while `RAILS_ENV` or `RACK_ENV` is `development` or `test`, and 503 everywhere else. `nil` opts out and serves it open, for a mount behind your own auth.
- `base_path`: where it is mounted. It defaults to `SCRIPT_NAME`, which `map` and Rails' `mount` set, so it is only needed when something strips the prefix without setting it.

The request's origin, used to refuse cross-site writes, and the `localhost` check come from the host and scheme Rack reports, which follow `X-Forwarded-Host` and `X-Forwarded-Proto`; behind a proxy, make sure those carry the public host and scheme. `/api/check` also accepts the client's `cron_secret` as a bearer. See [Dashboard and API](/docs/dashboard/) for every endpoint, and [Ruby on Rails](/docs/rails/#mount-the-dashboard) for the details.

## Stores

`Cronwatch::Stores::Memory.new` is the default. Nothing survives a restart, so a miss cannot be noticed across one, and each process has its own. The client warns when it is used with `RAILS_ENV` or `RACK_ENV` set to `production`.

`Cronwatch::Stores::ActiveRecord.new(prefix: "cronwatch_", connection_class: nil)` writes through ActiveRecord, to Postgres or SQLite, in three tables named `cronwatch_jobs`, `cronwatch_runs` and `cronwatch_state`. `prefix` is lowercase letters, digits and underscores, not starting with a digit, at most 47 characters. `connection_class` is the ActiveRecord class whose pool it uses (or its name, looked up on first use), `ActiveRecord::Base` by default; pass one that `connects_to` another database to keep the tables there. MySQL is untested and will not work as written: the statements use `ON CONFLICT` and `TEXT` primary keys.

The store never creates its tables. In Rails, `bin/rails generate cronwatch:install` writes the migration that does. Elsewhere, create them once:

```ruby
require "cronwatch/active_record"

ActiveRecord::Base.establish_connection(ENV.fetch("DATABASE_URL"))
Cronwatch::Stores::ActiveRecord.create_tables!                    # or (connection, prefix: "ops_")

CW = Cronwatch.new(store: Cronwatch::Stores::ActiveRecord.new)
```

`create_tables!(connection = ActiveRecord::Base.connection, prefix: "cronwatch_")` runs the SDK's own `CREATE TABLE IF NOT EXISTS` statements (on Postgres under the same advisory lock the Node store takes), and `drop_tables!` takes the same arguments. If the tables are missing, the client's first use of the store raises `Cronwatch::Stores::ActiveRecord::MissingTables`, naming them and the command that creates them. A run still goes ahead and hands the error to `on_error`; `check` raises it. The client looks again on its next call.

Each store call checks a connection out of the pool for just that call, so runs and checks in other threads are fine. Inside an open transaction the call runs in a savepoint, so a store error cannot abort your transaction; its rows still commit or roll back with it.

A store of your own is any object with the methods the memory store has: `upsert_job`, `get_job`, `list_jobs`, `delete_job`, `insert_run`, `update_run`, `get_run`, `list_runs`, `last_run`, `running_runs`, `get_state`, `set_state`, `prune`, and optionally `init` and `close`. They mean what the [TypeScript interface](/docs/stores/#writing-a-store) says, with epoch milliseconds for every time.

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

They use only the standard library. Every alert goes to every channel at once; a channel that raises, or takes longer than 15 seconds, goes to `on_error` and never holds up the others. A webhook signs its body with `X-CronWatch-Signature: sha256=<hex>` as the SDK's does, and its body is the same JSON. Verifying it in Ruby:

```ruby
expected = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", secret, request.raw_post)}"
ok = Rack::Utils.secure_compare(expected, request.headers["X-CronWatch-Signature"].to_s)
```

An alert has `type`, `job`, `definition`, `run`, `title`, `message`, `details`, `at` and `triage`. [Alerts](/docs/alerts/) describes each channel and the payload.

### Processes that cannot send

A job can run somewhere that cannot reach Slack or a mail relay: a sandboxed backup unit, a worker with no network, a script without the app's secrets. Give that process `deliver: :check`:

```ruby
RECORDER = Cronwatch.new(store: Cronwatch::Stores::ActiveRecord.new, deliver: :check)
```

It still records every run and evaluates it, but instead of sending an alert it queues it with the job's state. The next check in a process that sends normally (a `start` thread, `Cronwatch::CheckJob`, or whatever calls the check endpoint) delivers it, adds triage if that process has it, and marks it sent. Both processes must use the same store. See [processes that cannot send](/docs/alerts/#processes-that-cannot-send).

## Redaction

Before a run's output and error are stored, shown or sent to a channel or triage, `redact` rewrites them. The default, `Cronwatch::Output.redact_secrets`, blanks values that look like secrets: `password=...` and other secret-named pairs (quoted or not), credentials in URLs, bearer tokens, and AWS, GitHub, Slack, Stripe and API key formats. It matches exactly what the SDK's default matches. An `expect` rule is checked before redaction, so it still sees what was logged.

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

It runs only when an alert is sent, never per run, and never for a recovery. The client waits 25 seconds for it, then sends the alert without a diagnosis and reports the timeout to `on_error`. The `anthropic` gem cannot cancel a request under way, so the request is made once, without retries, with a 24 second timeout, and ends on its own before the client stops waiting. A refusal gives no diagnosis. What is sent is in [AI triage](/docs/triage/).

A triage of your own is any callable that takes the context (`alert`, `recent_runs`, `signal`) and returns a string or nil. `signal.aborted?` turns true, and `signal.check!` raises, once the client has stopped waiting; nothing is interrupted, so honour it if the work can stop early.

## API

`Cronwatch.new(**options)` and `Cronwatch.configure`:

| Option | Default | |
|---|---|---|
| `store` | in memory | a store |
| `alerts` | console | an array of channels: objects with `call(alert)` and `name`. `[]` sends nothing |
| `triage` | | a callable returning a diagnosis |
| `cron_secret` | `ENV["CRON_SECRET"]` | the bearer `/api/check` on `Cronwatch::Web` accepts beside the token. Empty counts as unset; `nil` means none on purpose |
| `retention` | `"30d"` | how long finished runs are kept. Each job's newest run is always kept |
| `defaults` | | `grace`, `timeout`, `timezone`, `failures_before_alert` applied to every job that does not set its own |
| `redact` | secret patterns | a callable applied to output and errors before they are stored or sent; `false` keeps them as logged. See [Redaction](#redaction) |
| `deliver` | `:now` | `:check` sends nothing from this process: alerts are queued in the store and the next check in a process that delivers now sends them, with triage. See [processes that cannot send](#processes-that-cannot-send) |
| `on_error` | `Rails.logger`, or a warning on standard error | `->(error, where) { ... }` for failures outside jobs: the store, a channel, triage |
| `now` | the system clock | a callable returning epoch milliseconds; for tests |

`client.job(name, **options)` takes `schedule`, `timezone`, `grace`, `timeout`, `max_duration`, `budget`, `expect` (a string, a Regexp or a callable), `failures_before_alert`, `description` and `tags`, with the defaults and rules in the [API reference](/docs/api/). A name is 1 to 120 letters, digits, `.`, `_`, `:` or `-`. Bad options raise `ArgumentError` when the job is declared. It returns a handle whose `run(trigger: "run") { |job| ... }` runs the block.

The block's `job` has `name`, `run_id`, `started_at`, `log(*parts)`, `metric(name, value)`, `metrics(hash)`, `signal`, and `aborted?`, true once the job's `timeout` has passed. Nothing is interrupted; a loop that can stop early checks it, or calls `job.signal.check!` to raise.

The client:

| Method | |
|---|---|
| `job(name, **options)` | declare a job and get its handle |
| `run(name, **options) { \|job\| ... }` | run without keeping a handle. Without a block, `run(id)` is `get_run(id)` |
| `check` | find missed and stuck runs, send alerts, retry alerts no channel accepted, prune. Returns a result with `checked_at`, `jobs`, `alerts` and `pruned`. Calls at the same time share one check |
| `start(every = "1m")`, `stop` | check in a background thread; the first check comes after a second, and the interval is at least 5 seconds |
| `jobs`, `jobs_with_runs(limit = 20)`, `job_summary(name)` | summaries, without alerting |
| `runs(name, limit = 50)`, `get_run(id)` | newest first; `limit` is 1 to 500 |
| `silence(name, for: "2h")`, `unsilence(name)` | stop alerts for a while; `silence(name, "2h")` works too. State keeps updating underneath |
| `forget(name)` | remove a job and its runs |
| `defined_jobs` | the definitions declared in this process |
| `close` | stop the thread and close the store |

## Sharing a database with Node

A Rails app and a Node service can watch their jobs in one database. The ActiveRecord store writes the same three tables as `@cronwatch/sdk/postgres` and `@cronwatch/sdk/sqlite`: the same names, columns and indexes, epoch milliseconds in the time columns, and the same JSON in the JSON columns. The gem's tests run the SDK's own stores in Node beside it, on SQLite and Postgres, and check that each reads what the other wrote, that the tables are the same whoever creates them, and that the rows are the same bytes in every column. Create the tables from either side; the other side's `CREATE TABLE IF NOT EXISTS` finds them and leaves them alone. Use the same prefix on both sides.

Each process alerts on the jobs it runs, and either side's check sees every job in the store. One dashboard, Rails or Node, shows them all, and one MCP server reads it. Give each job a name only one side uses.

## Kept in step

The TypeScript SDK is the source of truth. Its build generates cases (duration parsing, schedules across daylight saving, sequences of runs and checks with the alerts and state they must produce, alert titles and messages, stats and health) into `conformance/` in the repository, and the gem's tests replay every one. The dashboard is compared the same way: the gem's `Cronwatch::Web` must answer a fixed set of requests byte for byte as the SDK's routes do. A change of behaviour lands in TypeScript first, the cases are regenerated, and the gem is fixed until they pass. Where the two disagree, the gem is wrong: [open an issue](https://github.com/phillips-jon/cronwatch/issues).
