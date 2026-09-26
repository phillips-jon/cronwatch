---
title: Ruby on Rails
description: The cronwatch gem in a Rails app: the install generator, ActiveJob and Sidekiq jobs, schedules read from Solid Queue or sidekiq-cron, the check job and the dashboard.
order: 3.1
---

# Ruby on Rails

The `cronwatch` gem is the Ruby port of `@cronwatch/sdk`: the same conditions, the same alert text and the same stored rows. In Rails it records runs through ActiveRecord, watches your ActiveJob and Sidekiq classes, reads their schedules from Solid Queue or sidekiq-cron, and runs its check as a job of its own. It needs Ruby 3.2 or newer, and is tested on Rails 7.2, 8.0 and 8.1.

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

Bundler requires the gem after Rails has loaded, so `gem "cronwatch"` alone brings in the Rails integration: the Railtie, `Cronwatch::ActiveJob`, `Cronwatch::CheckJob`, the `cronwatch:check` task and the generator. With Sidekiq in the Gemfile (before or after `cronwatch`), `Cronwatch::Sidekiq` loads too. So does the dashboard, `Cronwatch::Web` (see [Mount the dashboard](#mount-the-dashboard)). The ActiveRecord store loads the first time it is used.

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

3. Run Cronwatch::CheckJob every 5 minutes, from one scheduler only. It notices
   the runs that never happen; two checkers would send each alert twice.

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

A class name is looked up on first use, so the initializer does not have to load the model. Each store call checks a connection out for just that call, always on the writing database, even inside a request Rails' automatic role switching runs on the reading one.

On Postgres the store never joins a transaction your code has open. A job that runs inside `ActiveRecord::Base.transaction` has its run recorded as it happens, and the run stays recorded if the transaction rolls back, so its alert is not sent again on the next failure. To do that the store connects through a pool of its own, with the writing database config of `connection_class` (`ActiveRecord::Base` by default): each process may open up to that config's `pool` (5 unless set) more connections, only as it needs them. Count them against your database's connection limit, or point `connection_class` at a class whose config sets a smaller `pool`. SQLite allows one writer at a time, so there the store uses your pool and, inside an open transaction, runs in a savepoint of it: a store error cannot abort your transaction, and the rows commit or roll back with it.

Postgres and SQLite are supported and tested. MySQL is not supported yet: the SDK's statements use `ON CONFLICT` and `TEXT` primary keys, and any other adapter is refused with `Cronwatch::Stores::ActiveRecord::UnsupportedAdapter` when the store is first used.

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

In production the app eager loads, so every job class is declared at boot. In development classes load on first use, so `Cronwatch::CheckJob` (and `bin/rails cronwatch:check`) loads `app/jobs` itself before checking, and `app/workers` and `app/sidekiq` when they exist. A monitored job kept elsewhere is known once its class has loaded.

## Sidekiq

Sidekiq jobs that include `Sidekiq::Job` (or `Sidekiq::Worker`) directly, without ActiveJob, include `Cronwatch::Sidekiq` beside it:

```ruby
class NightlyReportJob
  include Sidekiq::Job
  include Cronwatch::Sidekiq
  cronwatch schedule: "0 2 * * *", grace: "15m" # name: "nightly-report"

  def perform
    cronwatch.log("Report written")
  end
end
```

`cronwatch` takes the same options and follows the same rules as in an ActiveJob class: the same default name (`HardWorker` is `hard-worker`), declared once the app has booted, `cronwatch` inside `perform` for `log` and `metric`. Each `perform` is a run with the trigger `"sidekiq"`.

The runs are recorded by `Cronwatch::Sidekiq::ServerMiddleware`, which the Railtie adds to Sidekiq's server middleware when the process is a Sidekiq server; web processes are left alone. A job that raises is recorded as failed and the error goes on to Sidekiq, so retries, the dead set and your error handlers see it as before; each retry is a run of its own. Outside Rails, add the middleware yourself (see [Sidekiq without Rails](/docs/ruby/#sidekiq-without-rails)).

An ActiveJob class on Sidekiq's adapter keeps `Cronwatch::ActiveJob`. Sidekiq runs it inside ActiveJob's wrapper, which the middleware passes through, so the run is recorded once, by the ActiveJob side. Including `Cronwatch::Sidekiq` in an ActiveJob class raises.

To run the check from Sidekiq, schedule `Cronwatch::CheckJob` if ActiveJob uses Sidekiq's adapter, or `Cronwatch::Sidekiq::CheckWorker` if it does not; both do the same thing (see [Run the check](#run-the-check)). The worker does not retry: the next check comes five minutes later anyway.

## Schedule the job

CronWatch does not run anything; your scheduler still does. CronWatch has to know the schedule the scheduler keeps, so a job the scheduler never fires is still noticed. Rather than write it twice, take it from the scheduler's config:

```ruby
class NightlyReportJob < ApplicationJob
  include Cronwatch::ActiveJob
  cronwatch schedule: :from_scheduler, grace: "15m"
end
```

```yaml
# config/recurring.yml (Solid Queue)
production:
  nightly_report:
    class: NightlyReportJob
    schedule: every day at 2am
```

```yaml
# config/schedule.yml (sidekiq-cron)
nightly_report:
  cron: "every day at 2am"
  class: "NightlyReportJob"
```

`schedule: :from_scheduler` works the same in a `Cronwatch::Sidekiq` class. When the job is declared (at boot, in production), CronWatch finds the one enabled entry whose `class` is the job's class and turns its schedule into a cron expression and a timezone of its own. A class with no entry, or with more than one, stops the boot with an error that names the files it read; give such a class a `schedule:` of its own. `timezone:` cannot be given beside it, since the zone comes from the scheduler too.

Where it looks:

- Solid Queue, when it is loaded: `config/recurring.yml` (or the file `SOLID_QUEUE_RECURRING_SCHEDULE` names), the section for `Rails.env` when the file has one and the whole file when it does not, read as Solid Queue reads it (ERB, then YAML with dates and times allowed in `args`). Only tasks with a `schedule` count; tasks created at runtime (`SolidQueue.schedule_recurring_task`) are not in the file and are not seen. A file given to `bin/jobs` with `--recurring_schedule_file` is not seen either, since only the process that runs `bin/jobs` knows it: set `SOLID_QUEUE_RECURRING_SCHEDULE` instead, or list the file in `Cronwatch::Scheduler.sources`. With `SOLID_QUEUE_SKIP_RECURRING` set, Solid Queue runs no recurring tasks, and CronWatch reads none; where only this process skips them and another schedules them, pass `skip_recurring: false` to the source (below).
- sidekiq-cron, when it is loaded and enabled: its `cron_schedule_file` (`config/schedule.yml`, or `.yaml`), as a map of names to jobs or a list of jobs with `name`. A job with `status: disabled` does not count. Jobs created from code (`Sidekiq::Cron::Job.create`, or `load_from_hash` on a file of your own) are not seen.

To read something else, list the sources in the initializer:

```ruby
Cronwatch::Scheduler.sources = [
  Cronwatch::Scheduler::SolidQueue.new("config/recurring.yml"),
  Cronwatch::Scheduler::SidekiqCron.new("config/cron_jobs.yml"),   # or the Hash you pass to load_from_hash
]
```

`SolidQueue.new` also takes `env:` (the section to read), `time_zone:` (the zone for a schedule without one, an IANA name or a Rails name such as `"Eastern Time (US & Canada)"`; one that is neither stops the boot) and `skip_recurring:`.

### How schedules are converted

Both schedulers parse schedules with Fugit, which reads cron lines and phrases such as `every day at 3am`, `every 5 minutes` or `every hour at minute 12`. CronWatch reads cron expressions, not phrases, so each schedule is parsed with Fugit exactly as the scheduler parses it and written out as the cron expression Fugit made of it: `every day at 3am` is `0 3 * * *`, `every 5 minutes` is `0,5,10,15,20,25,30,35,40,45,50,55 * * * *`, `every hour at minute 12` is `12 * * * *`. What CronWatch expects is what the scheduler runs, even where the phrase says something else (Fugit reads `every 90 minutes` as every hour).

The timezone is the one the scheduler reads the schedule in: the zone at the end of the schedule (`every day at 3am America/New_York`, `0 2 * * * Europe/London`) when there is one. Without one, Solid Queue 1.5 and later use `config.solid_queue.time_zone`, which is `config.time_zone` unless you set it; sidekiq-cron and older Solid Queue use Fugit's local zone, which is `TZ`, then Rails' `Time.zone`, then the system's. A schedule with several times in one phrase (`every day at 9:15 and 17:30`) is refused by Solid Queue and read as its first time by sidekiq-cron's default `:single` mode, and CronWatch does the same.

Every conversion is checked against Fugit before it is used, by walking Fugit's runs and CronWatch's side by side from two days before to two days after every clock change in the next five years, and through a sample year: between two runs the scheduler makes, CronWatch must never expect one of its own. A difference CronWatch's minute of early slack explains is fine (in a burst such as `22-33 1 * * *`, the run at 01:32 already covers 01:33). The check takes a few tens of milliseconds for most schedules and up to about a second for one that fires every minute or more often, once, at boot. A schedule that fails is refused at boot with an error that says why, never approximated:

- Forms croner has no equivalent for: every other week (`1%2`), days counted back from the end of the month other than the last (`-2`, `5#-2`), random times (`~`).
- A zone that is not an IANA name, such as `+05:00`.
- A time that daylight saving skips. On the night clocks go forward, Fugit skips a run whose time does not exist (02:30 in New York in March), while CronWatch, like cron, expects it once the clocks have moved and would report it missed. So `every day at 2:30am` in a zone that changes at 02:00 is refused; a time outside the change, or a zone without daylight saving such as UTC, is fine. `every hour` is fine too: the skipped 02:00 lands on the 03:00 run. On the night clocks go back, Fugit runs a repeated time twice, and CronWatch counts the second run as an early one, so nothing is reported.
- A run Fugit drops on the day clocks change. Fugit's hour steps skip runs that exist: in New York `every 5 hours` (`0 */5 * * *`) runs at midnight and then not until 10:00 on the day clocks go forward, and `0 0,4 * * *` misses a run on the day they go back. Zones that change at midnight or by half an hour (`America/Havana`, `Australia/Lord_Howe`, `Pacific/Chatham`) have more such days.
- Any other schedule whose runs CronWatch would not expect exactly when the scheduler makes them. One known case: with both a day of the month and a day of the week (`0 0 1,15 * 1`), croner, and so CronWatch, skips some firsts of the month that Fugit runs.

A cron expression written by hand in both places still works, as before.

## Watch every recurring task

To watch everything the scheduler runs without touching each class, ask for it in the initializer:

```ruby
# config/initializers/cronwatch.rb, after Cronwatch.configure
Cronwatch.declare_from_scheduler!(grace: "10m")
```

Once the app has booted, every enabled entry in the scheduler's config becomes a job, with the schedule and zone converted as above, so the check reports one that never runs:

- A class that calls `cronwatch` declares itself, as usual; its entry is left to it.
- Any other class is named as `cronwatch` would name it (`DailyDigestJob` is `daily-digest`) and each of its performs is recorded: ActiveJob classes with the trigger `"active_job"`, Sidekiq jobs through the server middleware with `"sidekiq"`.
- A Solid Queue `command:` task is named after its key (`clear_solid_queue_finished_jobs`), and each run of Solid Queue's job with that command is recorded.
- `Cronwatch::CheckJob` and `Cronwatch::Sidekiq::CheckWorker` are left out.

It takes the options of a declared job other than `schedule`, `timezone` and `name` (`grace`, `timeout`, `failures_before_alert`, `tags`, and so on), applied to every job it declares; an entry's `description` becomes the job's. `except:` leaves keys out: `Cronwatch.declare_from_scheduler!(except: %w[one_off_import])`. An entry that cannot be watched stops the boot with an error that says so: a class that does not load, two entries that would be the same job (one class scheduled twice), a key that is not a valid job name, or a schedule that cannot be converted. Leave it out with `except:`, or give its class a `cronwatch` of its own.

Every perform of a watched class counts as a run, whoever enqueued it, as with `cronwatch`. Inside `perform`, `cronwatch` (for `log` and `metric`) exists only in a class that includes `Cronwatch::ActiveJob` or `Cronwatch::Sidekiq`.

## Run the check

**Run exactly one checker.** Schedule `Cronwatch::CheckJob` once, as one recurring entry, not per process or per machine, and do not also call `Cronwatch.client.start` or hit `/cronwatch/api/check` from elsewhere. Two checks against one database at the same moment can each open the same condition and send the same alert twice.

Failures are caught as they happen. A run that never started, or never finished, can only be noticed by looking. `Cronwatch::CheckJob` (or `Cronwatch::Sidekiq::CheckWorker`, for Sidekiq without ActiveJob) looks: it loads `app/jobs` when the app does not eager load, declares every monitored job, and calls `Cronwatch.client.check`, which finds missed and stuck runs, sends their alerts, retries alerts no channel accepted and prunes old runs. It returns the check's result and is queued on `default`. Schedule it every five minutes beside your other recurring jobs; these are the entries the generator prints.

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
  class: "Cronwatch::CheckJob"   # or "Cronwatch::Sidekiq::CheckWorker" when ActiveJob does not use Sidekiq
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
Rails.application.routes.draw do
  mount Cronwatch::Web.new(Cronwatch.client) => "/cronwatch"
end
```

`Cronwatch::Web` is a Rack app serving the same dashboard and JSON API as the TypeScript routes, at the same paths, with the same token rules. `gem "cronwatch"` loads it in a Rails app, so the route needs no `require`. `Cronwatch::Web.new(client = nil, token:, base_path:)` takes:

- `client`: the client to serve. Leave it out and each request uses `Cronwatch.client` at that moment.
- `token`: leave it out to read `CRONWATCH_TOKEN`. An empty string, passed or in the variable, counts as unset. `nil` opts out of the token entirely and serves the app to anyone who reaches it, for a mount that sits behind your own sign in.
- `base_path`: where it is mounted, so links resolve. It defaults to the mount point Rack reports (`SCRIPT_NAME`), which is right under Rails' `mount` and Rack's `map`.

Set `CRONWATCH_TOKEN` to a long random string and open `/cronwatch?token=<it>` once; the browser keeps a cookie holding a digest of the token. Scripts and the [MCP server](/docs/mcp/) send `Authorization: Bearer <token>` instead. Without a token, while `Rails.env` is `development` or `test`, it makes a token of its own (32 random bytes, new each time the app boots) and prints a sign-in link to the server's standard output on its first request:

```text
[cronwatch] CRONWATCH_TOKEN is not set, so this development server made a token for the dashboard. Sign in: http://localhost:3000/cronwatch/?token=...
```

Open that link once and the browser stays signed in; until then every request answers 401 and the page says the link is in the server log. Nothing about a request itself lets it in, since proxies, tunnels and `bin/rails server -b 0.0.0.0` all make a remote caller look local. In any other environment it answers 503 until a token is set.

To put it behind the app's own sign in instead, mount it inside that check and pass `token: nil`, so it serves whoever gets through. With Devise:

```ruby
authenticate :user, ->(user) { user.admin? } do
  mount Cronwatch::Web.new(Cronwatch.client, token: nil) => "/cronwatch"
end
```

Without Devise, a routing constraint does the same job: `constraints ->(request) { AdminSession.valid?(request) } do ... end` around the mount.

A `POST` or `DELETE` carrying an `Origin` that is not the request's own, or a `Sec-Fetch-Site` other than `same-origin` or `none`, is refused with 403, so another site cannot silence or forget a job with a signed-in cookie. The request's own origin reads the host and scheme Rack reports, which follow `X-Forwarded-Host` and `X-Forwarded-Proto`. Behind a proxy, make sure those (or `Host`) carry the public host and scheme, or the dashboard's own forms will look foreign.

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

It records and evaluates every run, but queues each alert in the store instead of sending it. The next check in a process that sends normally (the worker that runs `Cronwatch::CheckJob`, or whatever calls `/cronwatch/api/check`) delivers it, adds triage if that process has it, and marks it sent. Both must use the same database. A queued alert whose condition has closed since is dropped rather than sent late, and one check spends at most 20 seconds retrying across all jobs. See [processes that cannot send](/docs/alerts/#processes-that-cannot-send) and [Ruby](/docs/ruby/#processes-that-cannot-send).

Every process writes a job's state with a `version` that goes up on each write, and a write based on a stale read is refused and worked out again, so a web server, a Sidekiq process and a Node service sharing the database never lose each other's failures, alerts or silences.

## Development and tests

In development, reloading a job class runs its `cronwatch` declaration again. That is harmless: declarations are idempotent and the store is shared. Leave `CRONWATCH_TOKEN` unset locally and the dashboard makes a token of its own when the app boots and prints a sign-in link to the terminal running `bin/rails server` on its first request; open that link once. A restart makes a new token, and prints a new link.

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

Triage runs once per alert: when it gives nothing (it raised, timed out or answered empty) the alert's `triage` is `null` and it is not asked again on a retry. The Ruby options and defaults are in [Ruby](/docs/ruby/#triage); what is sent is in [AI triage](/docs/triage/).
