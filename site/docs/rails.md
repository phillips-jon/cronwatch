---
title: Ruby on Rails
description: The cronwatch gem in a Rails app: the install generator, ActiveJob, Solid Queue or sidekiq-cron, the check job and the dashboard.
order: 3.1
---

# Ruby on Rails

The `cronwatch` gem is the Ruby port of `@cronwatch/sdk`: the same conditions, the same alert text and the same stored rows. In Rails it records runs through ActiveRecord, watches your ActiveJob classes, and runs its check as a job of its own. It needs Ruby 3.2 or newer, and is tested on Rails 7.2, 8.0 and 8.1.

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

Bundler requires the gem after Rails has loaded, so `gem "cronwatch"` alone brings in the Rails integration: the Railtie, `Cronwatch::ActiveJob`, `Cronwatch::CheckJob`, the `cronwatch:check` task and the generator. The ActiveRecord store loads the first time it is used. The dashboard does not load on its own; see [Mount the dashboard](#mount-the-dashboard).

The generator writes two files:

- `db/migrate/<timestamp>_create_cronwatch_tables.rb`, which creates the three tables (`cronwatch_jobs`, `cronwatch_runs`, `cronwatch_state`) with the SDK's own statements, so a Node process can share them. Running the generator again leaves an existing migration alone.
- `config/initializers/cronwatch.rb`, which sets the store and the channels.

It takes two options. `--prefix ops_` names the tables `ops_jobs`, `ops_runs` and `ops_state`, in the migration and in the initializer's store; a prefix is lowercase letters, digits and underscores, and a bad one is refused before anything is written. `--database` (or `--db`) puts the migration in that database's migrations directory, in an app with several.

Rails needs the store. The web process, each worker and the check all have to see the same runs, and the in-memory store keeps each process's runs to itself (and warns about it in production). Leave the generated store line in.

When it is done the generator prints what to do next:

```
CronWatch is installed. Next:

1. Create the tables:

     bin/rails db:migrate

2. Monitor a job:

     class NightlyReportJob < ApplicationJob
       include Cronwatch::ActiveJob
       cronwatch schedule: "0 2 * * *", grace: "15m" # name: "nightly-report"
     end

3. Run Cronwatch::CheckJob every 5 minutes. It notices the runs that never happen.

   Solid Queue, in config/recurring.yml:

     production:
       cronwatch_check:
         class: Cronwatch::CheckJob
         schedule: every 5 minutes

   sidekiq-cron, in config/schedule.yml:

     cronwatch_check:
       cron: "*/5 * * * *"
       class: "Cronwatch::CheckJob"

   Or from a crontab: bin/rails cronwatch:check

4. Mount the dashboard in config/routes.rb:

     mount Cronwatch::Web.new(Cronwatch.client) => "/cronwatch"

   Outside development it needs CRONWATCH_TOKEN set to sign in.
```

The mount line needs `require "cronwatch/web"` above it, as shown [below](#mount-the-dashboard).

## The initializer

The generated one, trimmed to what it sets:

```ruby
# config/initializers/cronwatch.rb
Cronwatch.configure do |c|
  # Jobs, runs and alert state, in this app's database.
  c.store = Cronwatch::Stores::ActiveRecord.new

  # Where alerts go. With none set, they are written to standard error.
  c.alerts = [
    (Cronwatch::Alerts::Slack.new(webhook_url: ENV["SLACK_WEBHOOK_URL"]) if ENV["SLACK_WEBHOOK_URL"].present?),
    # Cronwatch::Alerts::Discord.new(webhook_url: ENV["DISCORD_WEBHOOK_URL"]),
    # Cronwatch::Alerts::Webhook.new(url: ENV["CRONWATCH_WEBHOOK_URL"], secret: ENV["CRONWATCH_WEBHOOK_SECRET"]),
  ].compact.presence

  # c.retention = "30d"
  # c.defaults = { grace: "10m", timezone: "Europe/London", failures_before_alert: 1 }
  # c.on_error = ->(error, where) { Rails.error.report(error, handled: true, context: { cronwatch: where }) }
  # c.cron_secret = Rails.application.credentials.cron_secret
end
```

`Cronwatch.configure` builds the one client the app uses, and `Cronwatch.client` returns it. Configuring again replaces the client. The settings are `store`, `alerts`, `triage`, `cron_secret`, `retention`, `defaults`, `redact`, `deliver`, `on_error` and `now`, the same as `Cronwatch.new` takes (see [Ruby](/docs/ruby/#api)); anything left unset takes the client's default. Errors outside jobs (the store, a channel, triage) go to `Rails.logger` unless `on_error` says otherwise.

The store takes `prefix:` and `connection_class:`. To keep the tables in another database, pass a class that `connects_to` it:

```ruby
c.store = Cronwatch::Stores::ActiveRecord.new(connection_class: "OpsRecord")
```

A class name is looked up on first use, so the initializer does not have to load the model. Each store call checks a connection out of that class's pool for just that call. Inside an open transaction it runs in a savepoint, so a store error cannot abort your transaction; its rows still commit or roll back with it. Postgres and SQLite are supported and tested. MySQL is untested and will not work as written: the statements use `ON CONFLICT` and `TEXT` primary keys.

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

Every `perform` is recorded as a run with the trigger `"active_job"`. The job is named after the class, without `Job`, underscored and dasherized, with `::` becoming `:`: `NightlyReportJob` is `nightly-report` and `Reports::NightlyJob` is `reports:nightly`. Pass `name:` to choose another; an anonymous class must. Keep names stable: they are the key everything in the store hangs off.

`cronwatch` takes `name` and the options a job declared by hand takes: `schedule`, `timezone`, `grace`, `timeout`, `max_duration`, `budget`, `expect`, `failures_before_alert`, `description` and `tags`. A bad option raises `ArgumentError`.

Only a class that calls `cronwatch` is monitored. Including the concern without it does nothing, and a subclass of a monitored job is not monitored until it calls `cronwatch` itself.

Inside a monitored `perform`, `cronwatch` is the run's context: `log(*parts)`, `metric(name, value)`, `metrics(hash)`, `aborted?` (true once `timeout` has passed), `signal`, `name`, `run_id` and `started_at`. Outside one (a class that is not monitored, or a direct call to `perform` that skips ActiveJob's callbacks) it is a stand-in that takes `log` and `metric` and drops them, so the job's code runs the same either way.

A job that raises still raises. The run is recorded as failed first, then the error goes on to ActiveJob, so `retry_on`, `discard_on` and your error reporter see it exactly as before. Each retry is a run of its own. To alert only when failures repeat, set `failures_before_alert`. A store that is down never stops a job: the job performs, unrecorded, and the error goes to `on_error`.

### When jobs are declared

The check can only report a job missing if the client knows the job's schedule, even when it has never run. Once the app has booted (after `config/initializers/cronwatch.rb`), the Railtie declares every class that has called `cronwatch` on `Cronwatch.client`. A class loaded after that declares itself as it loads. If `Cronwatch.configure` runs again, each class declares itself on the new client at its next perform or check. A bad declaration found at boot stops the boot.

In production the app eager loads, so every job class is declared at boot. In development classes load on first use, so `Cronwatch::CheckJob` (and `bin/rails cronwatch:check`) loads `app/jobs` itself before checking. A monitored job kept outside `app/jobs` is known once its class has loaded.

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

Failures are caught as they happen. A run that never started, or never finished, can only be noticed by looking. `Cronwatch::CheckJob` looks: it loads `app/jobs` when the app does not eager load, declares every monitored job, and calls `Cronwatch.client.check`, which finds missed and stuck runs, sends their alerts, retries alerts no channel accepted and prunes old runs. It returns the check's result and is queued on `default`. Schedule it every five minutes beside your other recurring jobs; these are the entries the generator prints.

Solid Queue:

```yaml
# config/recurring.yml
production:
  cronwatch_check:
    class: Cronwatch::CheckJob
    schedule: every 5 minutes
```

sidekiq-cron:

```yaml
# config/schedule.yml
cronwatch_check:
  cron: "*/5 * * * *"
  class: "Cronwatch::CheckJob"
```

With neither, `bin/rails cronwatch:check` runs the same job once and prints what it did (`cronwatch: checked 3 jobs, sent 0 alerts`), so a crontab line does it:

```
*/5 * * * *  cd /srv/app && bin/rails cronwatch:check
```

Nothing inside a Rails process checks on an interval: the Railtie starts no thread in web or worker processes, so schedule one of these.

If the scheduler itself stops, the check stops with it, and nothing inside the app can say so. Pair it with an uptime monitor for that case (see [Limits](/docs/limits/)).

## Mount the dashboard

```ruby
# config/routes.rb
require "cronwatch/web"

Rails.application.routes.draw do
  mount Cronwatch::Web.new(Cronwatch.client) => "/cronwatch"
end
```

`Cronwatch::Web` is a Rack app serving the same dashboard and JSON API as the TypeScript routes, at the same paths, with the same token rules. It is not loaded by `gem "cronwatch"`, hence the `require`. `Cronwatch::Web.new(client = nil, token:, base_path:)` takes:

- `client`: the client to serve. Leave it out and each request uses `Cronwatch.client` at that moment.
- `token`: leave it out to read `CRONWATCH_TOKEN`. An empty string, passed or in the variable, counts as unset. `nil` opts out of the token entirely and serves the app to anyone who reaches it, for a mount that sits behind your own sign in.
- `base_path`: where it is mounted, so links resolve. It defaults to the mount point Rack reports (`SCRIPT_NAME`), which is right under Rails' `mount` and Rack's `map`.

Set `CRONWATCH_TOKEN` to a long random string and open `/cronwatch?token=<it>` once; the browser keeps a cookie holding a digest of the token. Scripts and the [MCP server](/docs/mcp/) send `Authorization: Bearer <token>` instead. Without a token it answers only `localhost` while `RAILS_ENV` (or `RACK_ENV`) is `development` or `test`, and 503 everywhere else, including when neither is set.

To put it behind the app's own sign in instead, mount it inside that check and pass `token: nil`, so it serves whoever gets through. With Devise:

```ruby
authenticate :user, ->(user) { user.admin? } do
  mount Cronwatch::Web.new(Cronwatch.client, token: nil) => "/cronwatch"
end
```

Without Devise, a routing constraint does the same job: `constraints ->(request) { AdminSession.valid?(request) } do ... end` around the mount.

A `POST` or `DELETE` carrying an `Origin` that is not the request's own, or a `Sec-Fetch-Site` other than `same-origin` or `none`, is refused with 403, so another site cannot silence or forget a job with a signed-in cookie. The request's own origin and the `localhost` check both read the host and scheme Rack reports, which follow `X-Forwarded-Host` and `X-Forwarded-Proto`. Behind a proxy, make sure those (or `Host`) carry the public host and scheme, or the dashboard's own forms will look foreign. For the same reason, set a token on a development server other machines can reach.

`/cronwatch/api/check` runs the check. It accepts the token or, on this path only, the client's `cron_secret` (`CRON_SECRET` by default) as a bearer, so a platform cron or an outside scheduler can call it instead of `CheckJob` without holding the dashboard token. A `GET` must carry a bearer, so a page cannot set it off with the dashboard's cookie. [Dashboard and API](/docs/dashboard/) has every endpoint and JSON shape.

## Jobs triggered over HTTP

The TypeScript SDK's `handler()` has no Ruby counterpart: in Rails a controller action does that job. Declare the job once, after `Cronwatch.configure`, and wrap the action's body in its `run`:

```ruby
# config/initializers/cronwatch.rb, after Cronwatch.configure
CACHE_WARM = Cronwatch.client.job("cache-warm", schedule: "*/30 * * * *", grace: "5m")
```

```ruby
class CronController < ActionController::API
  before_action do
    secret = ENV["CRON_SECRET"].to_s
    given = request.authorization.to_s.delete_prefix("Bearer ")
    head :unauthorized unless secret.present? && ActiveSupport::SecurityUtils.secure_compare(given, secret)
  end

  def cache_warm
    CACHE_WARM.run(trigger: "handler") do |job|
      count = CacheWarmer.run
      job.log("Warmed #{count} keys")
    end
    head :ok
  end
end
```

The run is recorded however the action ends; an error is recorded and raised on to Rails, which answers 500. The action checks the bearer itself, because nothing in the gem guards your own routes. `CRON_SECRET` still guards `GET /cronwatch/api/check` on the mounted dashboard, as above.

## A worker that cannot send

A job can run somewhere that cannot reach Slack: a sandboxed worker, a box with no outbound network, a process without the app's secrets. Give that process `deliver: :check`:

```ruby
Cronwatch.configure do |c|
  c.store = Cronwatch::Stores::ActiveRecord.new
  c.deliver = ENV["CRONWATCH_DELIVER"] == "check" ? :check : :now
end
```

It records and evaluates every run, but queues each alert in the store instead of sending it. The next check in a process that sends normally (the worker that runs `Cronwatch::CheckJob`, or whatever calls `/cronwatch/api/check`) delivers it, adds triage if that process has it, and marks it sent. Both must use the same database. See [processes that cannot send](/docs/alerts/#processes-that-cannot-send).

## Development and tests

In development, reloading a job class runs its `cronwatch` declaration again. That is harmless: declarations are idempotent and the store is shared. Leave `CRONWATCH_TOKEN` unset locally and the dashboard is open at `localhost` (not at a LAN address or tunnel URL; set a token for those).

In tests, keep runs in memory and alerts quiet:

```ruby
# config/initializers/cronwatch.rb
Cronwatch.configure do |c|
  c.store  = Rails.env.test? ? Cronwatch::Stores::Memory.new : Cronwatch::Stores::ActiveRecord.new
  c.alerts = Rails.env.test? ? [] : [Cronwatch::Alerts::Slack.new(webhook_url: ENV["SLACK_WEBHOOK_URL"])]
end
```

An empty `alerts` array sends nothing; leaving `alerts` unset writes alerts to standard error.

## Triage

To attach a short diagnosis from Claude to every alert except recoveries, add `gem "anthropic"` (the official Anthropic gem) and set `ANTHROPIC_API_KEY`:

```ruby
require "cronwatch/triage/anthropic"

Cronwatch.configure do |c|
  # ...
  c.triage = Cronwatch::Triage::Anthropic.new(context: "A Rails 8 app on Postgres, jobs on Solid Queue.")
end
```

The Ruby options and defaults are in [Ruby](/docs/ruby/#triage); what is sent is in [AI triage](/docs/triage/).
