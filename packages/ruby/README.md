# cronwatch

Cron and scheduled-job monitoring that lives inside your Ruby or Rails app. Wrap a job once; every run is recorded in a database you already have, and you are told when a run is missed, fails, gets stuck, runs slow or goes over budget. No server to run, no account to make.

This is the Ruby port of [`@cronwatch/sdk`](https://www.npmjs.com/package/@cronwatch/sdk): the same rules, the same alert text and the same stored rows, so a Ruby process and a Node process can share one database, and [`@cronwatch/mcp`](https://www.npmjs.com/package/@cronwatch/mcp) works against either.

Docs: [cronwatch.dev/docs/rails](https://cronwatch.dev/docs/rails/) and [cronwatch.dev/docs/ruby](https://cronwatch.dev/docs/ruby/)

## Install

```ruby
# Gemfile
gem "cronwatch"
```

Ruby 3.2 or newer; the Rails integration is tested on Rails 7.2, 8.0 and 8.1. The only dependency is `fugit`, the cron parser Solid Queue and sidekiq-cron already bring. Everything else loads only from its own file:

| Require | For | Needs |
|---|---|---|
| `cronwatch` | the client, the memory store, and the Slack, Discord, webhook and console channels | |
| `cronwatch/active_record` | the ActiveRecord store | `activerecord` |
| `cronwatch/rails` | the Railtie, `Cronwatch::ActiveJob`, `Cronwatch::CheckJob`, the `cronwatch:check` task, the install generator | `railties`, `activejob` |
| `cronwatch/web` | the dashboard and JSON API as a Rack app | `rack` |
| `cronwatch/triage/anthropic` | Claude triage | `anthropic` |

In a Rails app, `gem "cronwatch"` also loads `cronwatch/rails` (Bundler requires it after Rails), and the ActiveRecord store loads on first use. `cronwatch/web` and `cronwatch/triage/anthropic` are always required by hand.

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

Client options: `store`, `alerts`, `triage`, `cron_secret`, `retention` (default `"30d"`), `defaults`, `redact` (default: blank values that look like secrets; `false` keeps output as logged, or pass a callable), `deliver` (`:now` by default; `:check` queues alerts for another process's check to send, for a worker that cannot reach Slack), `on_error` and `now`. Methods: `job`, `run`, `check`, `start`/`stop`, `silence(name, for: "2h")`/`unsilence`, `forget`, `jobs`, `jobs_with_runs`, `job_summary`, `runs`, `get_run`, `defined_jobs`, `close`. [cronwatch.dev/docs/ruby](https://cronwatch.dev/docs/ruby/#api) has each one.

## Rails

```bash
bundle add cronwatch
bin/rails generate cronwatch:install    # a migration and config/initializers/cronwatch.rb
bin/rails db:migrate
```

The generator takes `--prefix` (table prefix, default `cronwatch_`) and `--database` (the database whose migrations directory gets the migration). The initializer it writes sets the ActiveRecord store, which Rails needs so web, worker and check processes see the same runs:

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

Every `perform` is recorded as a run with the trigger `"active_job"`. The name defaults to the class name without `Job`, dasherized, with `::` as `:` (`Reports::NightlyJob` is `reports:nightly`); pass `name:` to choose another. Jobs are declared once the app has booted, so a check knows a job that has never run. A job that raises still raises after the run is recorded, so ActiveJob retries and your error reporter see it as before.

### Scheduling the check

Failures are caught as they happen, but a run that never started or never finished can only be noticed by looking. `Cronwatch::CheckJob` looks: it loads `app/jobs` when the app does not eager load, declares every monitored job and runs the check. Run it every five minutes.

Solid Queue:

```yaml
# config/recurring.yml
production:
  nightly_report:
    class: NightlyReportJob
    schedule: "0 2 * * * UTC"
  cronwatch_check:
    class: Cronwatch::CheckJob
    schedule: every 5 minutes
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

Or from a crontab: `bin/rails cronwatch:check`. Give the scheduler and the `cronwatch` declaration the same cron expression, so a job the scheduler never fires is still reported missing.

### Mounting the dashboard

```ruby
# config/routes.rb
Rails.application.routes.draw do
  mount Cronwatch::Web.new(Cronwatch.client) => "/cronwatch"
end
```

Set `CRONWATCH_TOKEN` to a long random string and open `/cronwatch?token=<it>` once; the browser keeps a cookie. Without a token it answers only `localhost` while `RAILS_ENV` or `RACK_ENV` is `development` or `test`, and 503 everywhere else. To rely on the app's own sign in, mount it behind that (Devise's `authenticate` block, or a routing constraint) and pass `token: nil`. The URLs, JSON shapes, headers and CSRF rules are the SDK's, so the MCP server reads it unchanged. `GET /cronwatch/api/check` with a bearer (the token or `CRON_SECRET`) runs the check, for an outside cron.

There is no `handler()` as in the TypeScript SDK: for a job triggered over HTTP, wrap the controller action's body in `CW.job(...).run` (declared once, at boot) and check the bearer in the controller.

In any other Rack app:

```ruby
# config.ru
require "cronwatch/web"
map("/cronwatch") { run Cronwatch::Web.new(CW) }
```

## Stores

- `Cronwatch::Stores::Memory.new`: the default. Nothing survives a restart.
- `Cronwatch::Stores::ActiveRecord.new(prefix: "cronwatch_", connection_class: nil)`: Postgres or SQLite through ActiveRecord, in `cronwatch_jobs`, `cronwatch_runs` and `cronwatch_state`. `connection_class` picks the pool (a class, or its name). In Rails the generator's migration creates the tables; elsewhere call `Cronwatch::Stores::ActiveRecord.create_tables!` (and `drop_tables!`). The store never creates them itself, and raises `MissingTables` when they are not there. Inside an open transaction each call runs in a savepoint. MySQL is untested.

Finished runs older than `retention` (default `"30d"`) are pruned by the check; each job's newest run is kept.

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
# Gemfile
gem "anthropic"
```

```ruby
require "cronwatch/triage/anthropic"

Cronwatch.configure do |c|
  c.triage = Cronwatch::Triage::Anthropic.new(context: "A Rails app on Postgres, jobs on Solid Queue.")
end
```

Adds two to four sentences from Claude (likely cause, first thing to check) to every alert except recoveries. Needs the `anthropic` gem and `ANTHROPIC_API_KEY`. It runs only when an alert is sent, never per run, and the alert goes out without it after 25 seconds. Options: `model` (default `"claude-opus-5"`), `effort` (`"medium"`), `max_tokens` (`800`), `context`, `fallbacks` (`true`), `api_key`, `client`.

## Sharing a database with a Node app

The ActiveRecord store writes the same three tables as `@cronwatch/sdk/postgres` and `@cronwatch/sdk/sqlite`: same names, columns and indexes, epoch milliseconds in the time columns, the SDK's camelCase JSON in the JSON columns. `test/active_record/node_compat_test.rb` runs the SDK's stores in Node beside this one, on SQLite and Postgres, and checks that each reads what the other wrote, that the tables are the same whoever creates them, and that the rows are the same bytes. Use the same prefix on both sides and give each job a name only one side uses. Then one dashboard, Rails or Node, shows every job, and one MCP server reads them all.

## Kept in step with the TypeScript SDK

The TypeScript SDK is the source of truth. `npm run conformance` at the repository root runs it and writes JSON cases to `conformance/`: duration parsing and formatting, schedules including daylight saving, sequences of runs and checks with the alerts and state they must produce, alert titles and messages, stats and health. This gem's tests replay every case, and the SDK's own check fails when the files are stale. A change of behaviour lands in TypeScript first, the cases are regenerated, and the gem is fixed until its tests pass. When the two disagree, the Ruby side is wrong.

The dashboard is held to the SDK the same way: `test/web/golden.json` records what the SDK's routes answer to a fixed set of requests, and `test/web_golden_test.rb` makes `Cronwatch::Web` answer them byte for byte.

The design of the port is in [DESIGN.md](DESIGN.md).

## Testing

```sh
bundle install
bundle exec rake test
```

`rake test` runs three suites, each in its own process: `rake test:core` (the client, channels, conformance, the Rack app), `rake test:active_record` (the store, on SQLite, and on Postgres when `CRONWATCH_TEST_PG` is set) and `rake test:rails` (a small Rails app: ActiveJob, `CheckJob`, the rake task, the generator).

```sh
CRONWATCH_TEST_PG=postgres://postgres:pw@127.0.0.1:5432/cw bundle exec rake test
```

The node compatibility tests run the built SDK and its drivers, and skip themselves otherwise, so build it first at the repository root:

```sh
npm ci && npm run build
```

The default Gemfile tests Rails 8.1. Each supported Rails series has its own Gemfile, with its own lockfile, in `test/rails/gemfiles`:

```sh
BUNDLE_GEMFILE=test/rails/gemfiles/rails_7_2.gemfile bundle install
BUNDLE_GEMFILE=test/rails/gemfiles/rails_7_2.gemfile bundle exec rake test
```

`rails_8_0.gemfile` and `rails_8_1.gemfile` work the same way. CI runs Ruby 3.2 with Rails 7.2, Ruby 3.4 with Rails 8.0 and 8.1, and Ruby 4.0 with Rails 8.1, all against Postgres.

When the SDK's routes or pages change, regenerate the dashboard fixture from the repository root:

```sh
npm run build --workspace packages/sdk && TZ=UTC node packages/ruby/test/web/golden.mjs
```

`npm run check` fails while `test/web/golden.json` or `conformance/` is stale.

The MCP server's tests can also drive this gem's `Cronwatch::Web` over HTTP (`test/web/server.rb`). They need `fugit`, `rack` and a server rackup can start (puma or webrick) in the Ruby they run, and only run when asked, from `packages/mcp`:

```sh
CRONWATCH_TEST_RUBY=1 CRONWATCH_RUBY="rbenv exec ruby" npm test
```

`CRONWATCH_RUBY` is the command that runs Ruby; it defaults to `ruby`.

## License

MIT, see [LICENSE](LICENSE).
