# cronwatch

Cron and scheduled-job monitoring that lives inside your Ruby or Rails app. Wrap a job once; every run is recorded in a database you already have, and you are told when a run is missed, fails, gets stuck, runs slow or goes over budget. No server to run, no account to make.

This is the Ruby port of [`@cronwatch/sdk`](https://www.npmjs.com/package/@cronwatch/sdk): the same rules, the same alert text and the same stored rows, so a Ruby process and a Node process can share one database, and [`@cronwatch/mcp`](https://www.npmjs.com/package/@cronwatch/mcp) works against either.

Docs: [cronwatch.dev/docs/rails](https://cronwatch.dev/docs/rails/) and [cronwatch.dev/docs/ruby](https://cronwatch.dev/docs/ruby/)

## Install

```ruby
# Gemfile
gem "cronwatch"
```

Ruby 3.2 or newer. The only dependency is `fugit`, the cron parser Solid Queue and sidekiq-cron already bring. Everything else loads only from its own file:

| Require | For | Needs |
|---|---|---|
| `cronwatch` | the client, the memory store, and the Slack, Discord, webhook and console channels | |
| `cronwatch/active_record` | the ActiveRecord store | `activerecord` |
| `cronwatch/rails` | the Railtie, `Cronwatch::ActiveJob`, `Cronwatch::CheckJob`, the install generator | `railties`, `activejob` |
| `cronwatch/web` | the dashboard and JSON API as a Rack app | `rack` |
| `cronwatch/triage/anthropic` | Claude triage | `anthropic` |

## Plain Ruby

```ruby
require "cronwatch"

CW = Cronwatch.new(
  alerts: [Cronwatch::Alerts::Slack.new(webhook_url: ENV.fetch("SLACK_WEBHOOK_URL"))],
)

NIGHTLY = CW.job("nightly-report",
  schedule: "0 2 * * *", timezone: "UTC", grace: "15m", timeout: "30m",
  expect: "Report written", budget: { cost: 2 })

NIGHTLY.run do |job|
  path = build_report
  job.log("Report written:", path)   # kept with the run, shown in alerts
  job.metric(:cost, 1.2)             # watched against budgets and baselines
end

CW.start # checks for missed and stuck runs every minute, in a background thread
```

`run` returns what the block returns and raises what it raises, after the run is recorded. A script run from crontab exits when it is done, so instead of `start`, add a second crontab line that declares the jobs and calls `CW.check` every five minutes.

## Rails

```bash
bundle add cronwatch
bin/rails generate cronwatch:install    # a migration and config/initializers/cronwatch.rb
bin/rails db:migrate
```

```ruby
# config/initializers/cronwatch.rb
Cronwatch.configure do |c|
  c.store  = Cronwatch::Stores::ActiveRecord.new
  c.alerts = [Cronwatch::Alerts::Slack.new(webhook_url: ENV["SLACK_WEBHOOK_URL"])]
end
```

`Cronwatch.configure` builds the app's client; `Cronwatch.client` returns it.

### ActiveJob

```ruby
class NightlyReportJob < ApplicationJob
  include Cronwatch::ActiveJob
  cronwatch schedule: "0 2 * * *", grace: "15m", expect: "Report written"   # name: "nightly-report"

  def perform
    cronwatch.log("Report written")
    cronwatch.metric(:cost, 1.2)
  end
end
```

Every `perform` is recorded as a run. The name defaults to the class name without `Job`, dasherized; pass `name:` to choose another. A job that raises still raises after the run is recorded, so ActiveJob retries and your error reporter see it as before.

### Scheduling the check

Failures are caught as they happen, but a run that never started or never finished can only be noticed by looking. `Cronwatch::CheckJob` looks. Run it every five minutes.

Solid Queue:

```yaml
# config/recurring.yml
production:
  nightly_report:
    class: NightlyReportJob
    schedule: "0 2 * * * UTC"
  cronwatch_check:
    class: Cronwatch::CheckJob
    schedule: "*/5 * * * *"
```

sidekiq-cron:

```yaml
# config/schedule.yml
nightly_report:
  cron: "0 2 * * * UTC"
  class: "NightlyReportJob"
cronwatch_check:
  cron: "*/5 * * * *"
  class: "Cronwatch::CheckJob"
```

Give the scheduler and the `cronwatch` declaration the same cron expression, so a job the scheduler never fires is still reported missing.

### Mounting the dashboard

```ruby
# config/routes.rb
mount Cronwatch::Web.new(Cronwatch.client) => "/cronwatch"
```

Set `CRONWATCH_TOKEN` to a long random string and open `/cronwatch?token=<it>` once; the browser keeps a cookie. Without a token it answers only `localhost` while `RAILS_ENV` or `RACK_ENV` is `development` or `test`, and 503 everywhere else. To rely on the app's own sign in, mount it behind that and pass `token: nil`. The URLs, JSON shapes, headers and CSRF rules are the SDK's, so the MCP server reads it unchanged. `GET /cronwatch/api/check` with a bearer (the token or `CRON_SECRET`) runs the check, for an outside cron.

In any other Rack app:

```ruby
# config.ru
require "cronwatch/web"
map("/cronwatch") { run Cronwatch::Web.new(CW) }
```

## Stores

- `Cronwatch::Stores::Memory.new`: the default. Nothing survives a restart.
- `Cronwatch::Stores::ActiveRecord.new`: Postgres or SQLite through the app's ActiveRecord connection, in `cronwatch_jobs`, `cronwatch_runs` and `cronwatch_state` (pass `prefix:` to change `cronwatch_`). In Rails the generator's migration creates the tables; the store never does.

Finished runs older than `retention` (default `"30d"`) are pruned by the check.

## Alerts

```ruby
Cronwatch::Alerts::Slack.new(webhook_url: ENV.fetch("SLACK_WEBHOOK_URL"))
Cronwatch::Alerts::Discord.new(webhook_url: ENV.fetch("DISCORD_WEBHOOK_URL"))
Cronwatch::Alerts::Webhook.new(url: "https://hooks.example.com/cronwatch", secret: ENV["CRONWATCH_WEBHOOK_SECRET"])
Cronwatch::Alerts::Console.new   # the default

Cronwatch::Alerts::Custom.new("pagerduty") do |alert|
  next if alert.type == :recovered
  PagerDuty.trigger(summary: alert.title, details: alert.message)
end
```

Every alert goes to every channel. A channel that raises, or takes longer than 15 seconds, goes to `on_error` and never blocks the others. Each condition alerts once when it opens and once more when a clean run closes it; there are no repeat alerts. The webhook signs its body with `X-CronWatch-Signature: sha256=<hex>`, the HMAC-SHA256 of the raw body.

## Triage

```ruby
require "cronwatch/triage/anthropic"

Cronwatch.configure do |c|
  c.triage = Cronwatch::Triage::Anthropic.new(context: "A Rails app on Postgres, jobs on Solid Queue.")
end
```

Adds two to four sentences from Claude (likely cause, first thing to check) to every alert except recoveries. Needs the `anthropic` gem and `ANTHROPIC_API_KEY`. It runs only when an alert is sent, never per run. Options: `model`, `effort`, `max_tokens`, `context`, `fallbacks`, `api_key`, `client`.

## Sharing a database with a Node app

The ActiveRecord store writes the same three tables as `@cronwatch/sdk/postgres` and `@cronwatch/sdk/sqlite`: same names, same columns, epoch milliseconds in the time columns, the SDK's camelCase JSON in the JSON columns. Create the tables with the Rails migration; the Node store's `CREATE TABLE IF NOT EXISTS` leaves them alone. Use the same prefix on both sides and give each job a name only one side uses. Then one dashboard, Rails or Node, shows every job, and one MCP server reads them all.

## Kept in step with the TypeScript SDK

The TypeScript SDK is the source of truth. `npm run conformance` at the repository root runs it and writes JSON cases to `conformance/`: duration parsing and formatting, schedules including daylight saving, sequences of runs and checks with the alerts and state they must produce, alert titles and messages, stats and health. This gem's tests replay every case, and the SDK's own check fails when the files are stale. A change of behaviour lands in TypeScript first, the cases are regenerated, and the gem is fixed until its tests pass. When the two disagree, the Ruby side is wrong.

The design of the port is in [DESIGN.md](DESIGN.md).

## Development

```sh
bundle install
bundle exec rake test
```

Postgres tests run when `CRONWATCH_TEST_PG` points at a database. Some tests compare against the built SDK, so run `npm ci && npm run build --workspace packages/sdk` at the repository root first.

## License

MIT, see [LICENSE](LICENSE).
