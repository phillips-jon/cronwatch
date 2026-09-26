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

Ruby 3.2 or newer. The only dependency is `fugit`, the cron parser Solid Queue and sidekiq-cron already bring. Everything else loads only when you require it:

| Require | For | Needs |
|---|---|---|
| `cronwatch` | the client, the memory store, and the Slack, Discord, webhook and console channels | |
| `cronwatch/active_record` | the ActiveRecord store | `activerecord` |
| `cronwatch/rails` | the Railtie, `Cronwatch::ActiveJob`, `Cronwatch::CheckJob`, the install generator | `railties`, `activejob` |
| `cronwatch/web` | the dashboard and JSON API as a Rack app | `rack` |
| `cronwatch/triage/anthropic` | Claude triage | `anthropic` |

In a Rails app, `gem "cronwatch"` in the Gemfile is all it takes; [Ruby on Rails](/docs/rails/) has the rest.

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

Option names are snake_case (`max_duration`, `failures_before_alert`); conditions and alert types are symbols (`:missed`, `:over_budget`, `:recovered`). Durations are strings such as `"15m"` or `"1h30m"`. Anything that leaves the process (store rows, the JSON API, webhook bodies) uses the SDK's camelCase field names and string values.

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

Sinatra, Hanami and Roda mount it the same way. It serves the same pages and JSON API as the TypeScript routes, with the same token rules, reading `RAILS_ENV` or `RACK_ENV` where the SDK reads `NODE_ENV`. See [Dashboard and API](/docs/dashboard/).

## Stores

`Cronwatch::Stores::Memory.new` is the default. Nothing survives a restart, so a miss cannot be noticed across one.

`Cronwatch::Stores::ActiveRecord.new` writes to the database ActiveRecord is connected to, Postgres or SQLite, in three tables named `cronwatch_jobs`, `cronwatch_runs` and `cronwatch_state`. In Rails, `rails generate cronwatch:install` writes the migration that creates them. Pass `prefix:` to change `cronwatch_`; the same rules apply as for the [SQL stores](/docs/stores/), and the migration must use the same prefix.

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

They use only the standard library. A webhook signs its body with `X-CronWatch-Signature: sha256=<hex>` as the SDK's does, and its body is the same JSON. Verifying it in Ruby:

```ruby
expected = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", secret, request.raw_post)}"
ok = Rack::Utils.secure_compare(expected, request.headers["X-CronWatch-Signature"].to_s)
```

An alert has `type`, `job`, `definition`, `run`, `title`, `message`, `details`, `at` and `triage`. [Alerts](/docs/alerts/) describes each channel and the payload.

## Triage

```ruby
require "cronwatch/triage/anthropic"

CW = Cronwatch.new(
  triage: Cronwatch::Triage::Anthropic.new(context: "A Sinatra app on Postgres, jobs run from crontab."),
)
```

It takes `model`, `effort`, `max_tokens`, `context`, `fallbacks`, `api_key` and `client`, with the defaults in [AI triage](/docs/triage/). The key comes from `ANTHROPIC_API_KEY` unless you pass one. A triage of your own is any callable that takes the context (`alert`, `recent_runs`, `signal`) and returns a string or nil.

## API

`Cronwatch.new(**options)` and `Cronwatch.configure`:

| Option | Default | |
|---|---|---|
| `store` | in memory | a store |
| `alerts` | console | an array of channels: objects with `call(alert)` and `name` |
| `triage` | | a callable returning a diagnosis |
| `cron_secret` | `ENV["CRON_SECRET"]` | the bearer `GET /api/check` also accepts. Empty counts as unset; `nil` means none on purpose |
| `retention` | `"30d"` | how long finished runs are kept |
| `defaults` | | `grace`, `timeout`, `timezone`, `failures_before_alert` applied to every job |
| `on_error` | `Rails.logger`, or a warning | `->(error, where) { ... }` for failures outside jobs: the store, a channel, triage |
| `now` | the system clock | a callable returning epoch milliseconds; for tests |

`client.job(name, **options)` takes `schedule`, `timezone`, `grace`, `timeout`, `max_duration`, `budget`, `expect` (a string, a Regexp or a callable), `failures_before_alert`, `description` and `tags`, with the defaults and rules in the [API reference](/docs/api/). Bad options raise `ArgumentError` when the job is declared. It returns a handle whose `run(trigger: "run") { |job| ... }` runs the block.

The block's `job` has `name`, `run_id`, `started_at`, `log(*parts)`, `metric(name, value)`, `metrics(hash)`, and `aborted?`, true once the job's `timeout` has passed. Nothing is interrupted; a loop that can stop early checks it, or calls `job.signal.check!` to raise.

The client:

| Method | |
|---|---|
| `run(name, **options) { \|job\| ... }` | run without keeping a handle |
| `check` | find missed and stuck runs, send alerts, retry alerts no channel accepted, prune. Returns a result with `checked_at`, `jobs`, `alerts` and `pruned` |
| `start(every = "1m")`, `stop` | check in a background thread |
| `jobs`, `jobs_with_runs(limit = 20)`, `job_summary(name)` | summaries, without alerting |
| `runs(name, limit = 50)`, `get_run(id)` | newest first; `limit` is 1 to 500 |
| `silence(name, for: "2h")`, `unsilence(name)` | |
| `forget(name)` | remove a job and its runs |
| `defined_jobs` | the definitions declared in this process |
| `close` | stop the thread and close the store |

## Sharing a database with Node

A Rails app and a Node service can watch their jobs in one database. The ActiveRecord store writes the same three tables as `@cronwatch/sdk/postgres` and `@cronwatch/sdk/sqlite`: the same names, the same columns, epoch milliseconds in the time columns, and the same JSON in the JSON columns. Create them with the Rails migration; the Node store's `CREATE TABLE IF NOT EXISTS` finds them and leaves them alone. Use the same prefix on both sides.

Each process alerts on the jobs it runs, and either side's check sees every job in the store. One dashboard, Rails or Node, shows them all, and one MCP server reads it. Give each job a name only one side uses.

## Kept in step

The TypeScript SDK is the source of truth. Its build generates cases (duration parsing, schedules across daylight saving, sequences of runs and checks with the alerts and state they must produce, alert titles and messages, stats and health) into `conformance/` in the repository, and the gem's tests replay every one. A change of behaviour lands in TypeScript first, the cases are regenerated, and the gem is fixed until they pass. Where the two disagree, the gem is wrong: [open an issue](https://github.com/phillips-jon/cronwatch/issues).
