---
title: Ruby on Rails
description: The cronwatch gem in a Rails app: the install generator, ActiveJob, Solid Queue or sidekiq-cron, the check job and the dashboard.
order: 3.1
---

# Ruby on Rails

The `cronwatch` gem is the Ruby port of `@cronwatch/sdk`: the same conditions, the same alert text and the same stored rows. In Rails it records runs through ActiveRecord, watches your ActiveJob classes, and runs its check as a job of its own. It needs Ruby 3.2 or newer.

## Install

```ruby
# Gemfile
gem "cronwatch"
```

```bash
bundle install
bin/rails generate cronwatch:install
bin/rails db:migrate
```

The generator writes two files: a migration that creates the three tables (`cronwatch_jobs`, `cronwatch_runs`, `cronwatch_state`) and an initializer. The ActiveRecord store never creates tables itself in Rails; the migration does. Postgres and SQLite are supported.

## The initializer

```ruby
# config/initializers/cronwatch.rb
Cronwatch.configure do |c|
  c.store  = Cronwatch::Stores::ActiveRecord.new
  c.alerts = [Cronwatch::Alerts::Slack.new(webhook_url: ENV["SLACK_WEBHOOK_URL"])]
  c.defaults = { timezone: "UTC" }
  c.on_error = ->(error, where) { Rails.error.report(error, handled: true, context: { cronwatch: where }) }
end
```

`Cronwatch.configure` builds the one client the app uses, and `Cronwatch.client` returns it. Every setting is optional: without a store, runs live in memory and vanish on restart; without alerts, they go to the console. The settings are `store`, `alerts`, `triage`, `cron_secret`, `retention`, `defaults` and `on_error`, the same as `Cronwatch.new` takes (see [Ruby](/docs/ruby/)).

## Watch a job

Include `Cronwatch::ActiveJob` and declare the schedule the job is supposed to keep:

```ruby
class NightlyReportJob < ApplicationJob
  include Cronwatch::ActiveJob
  cronwatch schedule: "0 2 * * *", grace: "15m", timeout: "30m", expect: "Report written"

  def perform
    report = Reports::Nightly.build
    cronwatch.log("Report written:", report.path)   # kept with the run, shown in alerts
    cronwatch.metric(:cost, report.usd_cost)        # watched against budgets and baselines
  end
end
```

Every `perform` is recorded as a run. The job is named after the class, without `Job`, dasherized: `NightlyReportJob` is `nightly-report`. Pass `name:` to choose another. Keep names stable: they are the key everything in the store hangs off.

`cronwatch` takes the same options as a job declared by hand: `schedule`, `timezone`, `grace`, `timeout`, `max_duration`, `budget`, `expect`, `failures_before_alert`, `description` and `tags`. Inside `perform`, `cronwatch` is the run's context, with `log`, `metric`, `metrics` and `aborted?`.

A job that raises still raises. The run is recorded as failed first, then the error goes on to ActiveJob, so retries, `retry_on`, `discard_on` and your error reporter see it exactly as before. Each retry is a run of its own. To alert only when failures repeat, set `failures_before_alert`.

## Schedule the job

CronWatch does not run anything; your scheduler still does. Give CronWatch the same schedule you give the scheduler, as a cron expression, so a job the scheduler never fires is still noticed.

Solid Queue:

```yaml
# config/recurring.yml
production:
  nightly_report:
    class: NightlyReportJob
    schedule: "0 2 * * * UTC"
```

sidekiq-cron:

```yaml
# config/schedule.yml
nightly_report:
  cron: "0 2 * * * UTC"
  class: "NightlyReportJob"
```

Solid Queue and sidekiq-cron also accept phrases such as `every day at 2am`. CronWatch reads cron expressions, nicknames such as `@hourly`, and `every 15m`, so use a cron expression in both places and they cannot drift apart.

## Run the check

Failures are caught as they happen. A run that never started, or never finished, can only be noticed by looking. `Cronwatch::CheckJob` looks: it calls `Cronwatch.client.check`, which finds missed and stuck runs, sends their alerts, retries alerts no channel accepted and prunes old runs. Schedule it every five minutes beside your other recurring jobs.

Solid Queue:

```yaml
# config/recurring.yml
production:
  cronwatch_check:
    class: Cronwatch::CheckJob
    schedule: "*/5 * * * *"
```

sidekiq-cron:

```yaml
# config/schedule.yml
cronwatch_check:
  cron: "*/5 * * * *"
  class: "Cronwatch::CheckJob"
```

With neither, a crontab line does the same:

```
*/5 * * * *  cd /srv/app && bin/rails runner 'Cronwatch.client.check'
```

A job is known to the store once a process has declared it, and the `cronwatch` macro declares it when the class loads. Production eager loads every class at boot, so the worker that runs the check knows every watched job, including one that has never run and so can be reported missing. If your worker does not eager load, a job that has never run is not known until its class is loaded.

If the scheduler itself stops, the check stops with it, and nothing inside the app can say so. Pair it with an uptime monitor for that case (see [Limits](/docs/limits/)).

## Mount the dashboard

```ruby
# config/routes.rb
mount Cronwatch::Web.new(Cronwatch.client) => "/cronwatch"
```

`Cronwatch::Web` is a Rack app serving the same dashboard and JSON API as the TypeScript routes, at the same paths, with the same token rules. Set `CRONWATCH_TOKEN` to a long random string and open `/cronwatch?token=<it>` once; the browser keeps a cookie. Without a token it answers only `localhost` while `RAILS_ENV` (or `RACK_ENV`) is `development` or `test`, and 503 everywhere else.

To put it behind the app's own sign in instead, mount it inside that check and pass `token: nil`, so it serves whoever gets through. With Devise:

```ruby
authenticate :user, ->(user) { user.admin? } do
  mount Cronwatch::Web.new(Cronwatch.client, token: nil) => "/cronwatch"
end
```

`GET /cronwatch/api/check` runs the check for a request with a bearer (the token or `CRON_SECRET`), so a platform cron or an outside scheduler can call it instead of `CheckJob`. The [MCP server](/docs/mcp/) reads the same API. [Dashboard and API](/docs/dashboard/) has every endpoint and JSON shape.

## Development and tests

In development, reloading a job class runs its `cronwatch` declaration again. That is harmless: declarations are idempotent and the store is shared. Leave `CRONWATCH_TOKEN` unset locally and the dashboard is open at `localhost`.

In tests, keep runs in memory and alerts quiet:

```ruby
# config/initializers/cronwatch.rb
Cronwatch.configure do |c|
  c.store  = Rails.env.test? ? Cronwatch::Stores::Memory.new : Cronwatch::Stores::ActiveRecord.new
  c.alerts = Rails.env.test? ? [] : [Cronwatch::Alerts::Slack.new(webhook_url: ENV["SLACK_WEBHOOK_URL"])]
end
```

## Triage

To attach a short diagnosis from Claude to every alert except recoveries, add the `anthropic` gem and set `ANTHROPIC_API_KEY`:

```ruby
require "cronwatch/triage/anthropic"

Cronwatch.configure do |c|
  # ...
  c.triage = Cronwatch::Triage::Anthropic.new(context: "A Rails 8 app on Postgres, jobs on Solid Queue.")
end
```

The options and what is sent are in [AI triage](/docs/triage/); the Ruby names are snake_case (`max_tokens`, `api_key`).
