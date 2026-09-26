# The Ruby port

`packages/ruby` is the `cronwatch` gem: the same library as `@cronwatch/sdk`, for Ruby and Rails apps. It is a port, not a new design. The TypeScript SDK is the source of truth for every behaviour, message and stored byte; when the two disagree, the Ruby side is wrong.

## Rules

- Ruby 3.2 or newer. The only runtime dependency is `fugit` (the cron parser Solid Queue and sidekiq-cron already bring). Everything else is optional and loaded only from its own file, like the SDK's entry points:
  - `require "cronwatch/active_record"`: the ActiveRecord store (needs `activerecord`)
  - `require "cronwatch/rails"`: Railtie, ActiveJob integration, `Cronwatch::CheckJob`, install generator (needs `railties`, `activejob`)
  - `require "cronwatch/web"`: the Rack dashboard and JSON API (needs `rack`)
  - `require "cronwatch/triage/anthropic"`: Claude triage (needs the `anthropic` gem)
  - Slack, Discord, webhook and console channels use only the standard library and load with the core.
- Times are Integer epoch milliseconds everywhere, as in the SDK, so `evaluate` ports line for line and stored rows are identical.
- Ruby API names are snake_case (`failures_before_alert`, `max_duration`, `started_at`). Conditions and alert types are symbols (`:missed`, `:over_budget`, `:recovered`). Anything that leaves the process (store rows, JSON columns, the JSON API, webhook payloads) uses the SDK's exact camelCase field names and string values, so a Node process and a Ruby process can share one database and `@cronwatch/mcp` works against either.
- Alert titles and messages are the SDK's text, character for character.
- Every condition opens once and closes with a recovery. No repeat alerts.
- No em or en dashes anywhere, as in the rest of the repo.

## Layout

```
packages/ruby/
  cronwatch.gemspec  Gemfile  Rakefile  README.md  LICENSE  DESIGN.md
  lib/cronwatch.rb                 Cronwatch.new, Cronwatch.configure / Cronwatch.client
  lib/cronwatch/
    version.rb duration.rb schedule.rb evaluate.rb stats.rb output.rb format.rb serialize.rb
    types.rb        Run, JobState, StoredJob, Alert, JobSummary, CheckResult (Structs)
    client.rb       the client: job, run, check, start/stop, silence, unsilence, forget, jobs, job_summary, runs, close
    job.rb          JobHandle (#run) and the context passed to the block (#log, #metric, #signal)
    stores/memory.rb
    alerts/console.rb slack.rb discord.rb webhook.rb custom.rb
    active_record.rb  stores/active_record.rb
    web.rb  web/app.rb web/html.rb
    rails.rb  rails/railtie.rb rails/active_job.rb rails/check_job.rb
    triage/anthropic.rb
  lib/generators/cronwatch/install/  (migration + initializer templates)
  test/
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

# config/recurring.yml (Solid Queue) or sidekiq-cron: run Cronwatch::CheckJob every 5 minutes.
# config/routes.rb: mount Cronwatch::Web.new(Cronwatch.client) => "/cronwatch"
```

The job name defaults to the class name without `Job`, dasherized (`NightlyReportJob` is `nightly-report`). A job raising still raises after the run is recorded, so ActiveJob retries and error reporters see it as before.

## Keeping the two in step

`conformance/` at the repo root holds JSON cases generated from the TypeScript build by `scripts/conformance.mjs`: duration parsing and formatting, schedule parsing and due/deadline/covers (including daylight saving), sequences of run and check events with the alerts and state they must produce, alert titles and messages, stats and health. The SDK's tests fail when the files are stale, and the gem's tests replay every case. A behaviour change lands in TypeScript first, the fixtures are regenerated, and the gem is fixed until they pass.

## Storage

The ActiveRecord store writes the same three tables as `packages/sdk/src/stores/sql.ts` (same names, `cronwatch_` prefix by default, same columns, same JSON in the JSON columns). The install generator creates them with a Rails migration; the store never creates tables itself in Rails. Postgres and SQLite are supported and tested.

## Web

`Cronwatch::Web` is a Rack app with the SDK routes' URLs, JSON shapes, auth and headers: bearer or cookie token (`CRONWATCH_TOKEN`), `?token=` only on the HTML sign in, fail closed outside development and test (`RAILS_ENV`/`RACK_ENV` instead of `NODE_ENV`), the same CSRF and CSP rules, and `GET /api/check` with a bearer (the token or `CRON_SECRET`).
