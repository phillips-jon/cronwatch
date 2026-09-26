# CronWatch

Cron and scheduled-job monitoring that lives inside your app. Wrap a job once; CronWatch records every run in a database you already have and tells you when a run is missed, fails, gets stuck, runs slow or goes over budget. No server to run, no account to make. MIT.

**Site and docs:** [cronwatch.dev](https://cronwatch.dev)

```ts
// lib/cronwatch.ts
import { cronwatch } from "@cronwatch/sdk";
import { sqlite } from "@cronwatch/sdk/sqlite";
import { slack } from "@cronwatch/sdk/slack";

export const cw = cronwatch({
  store: sqlite({ path: "./data/cronwatch.db" }),
  alerts: [slack({ webhookUrl: process.env.SLACK_WEBHOOK_URL! })],
});

export const nightlyReport = cw.job("nightly-report", {
  schedule: "0 2 * * *", timezone: "UTC", grace: "15m", expect: "Report written",
});
```

```ts
// app/api/cron/nightly-report/route.ts: checks Authorization: Bearer CRON_SECRET
import { nightlyReport } from "@/lib/cronwatch";

export const GET = nightlyReport.handler(async (job) => {
  const report = await buildReport();
  job.log("Report written:", report.path);
  job.metric("cost", report.usdCost);
});
```

```ts
// app/cronwatch/[[...path]]/route.ts: a dashboard and JSON API behind CRONWATCH_TOKEN
import { cw } from "@/lib/cronwatch";

export const { GET, POST, DELETE } = cw.routes();
```

## Packages

| Package | What |
|---|---|
| [`@cronwatch/sdk`](packages/sdk) | the library: jobs, runs, checks, stores (memory, SQLite, Postgres), alerts (Slack, Discord, webhook), dashboard and API, optional Claude triage |
| [`cronwatch` gem](packages/ruby) | the Ruby port for Ruby and Rails apps: ActiveRecord store, ActiveJob and Sidekiq integration, schedules read from Solid Queue or sidekiq-cron, a check job, the dashboard as a Rack app. Same rules, alerts and stored rows as the SDK |
| [`@cronwatch/mcp`](packages/mcp) | an MCP server so Claude Code, Cursor and other agents can list jobs, read failures, run a check and silence alerts |
| [`skills/cronwatch`](skills/cronwatch) | a Claude Code skill: how to add monitoring to a job and how to investigate a failure |
| [`site`](site) | cronwatch.dev, a static landing page and docs |

## Installing

TypeScript and Node: `npm install @cronwatch/sdk`. Ruby and Rails: `bundle add cronwatch` (see [Ruby and Rails](#ruby-and-rails)).

The SDK needs Node 22 or newer and depends only on `croner`. Each driver is an optional peer, installed only when you use its entry point:

| Entry point | Install |
|---|---|
| `@cronwatch/sdk/sqlite` | `better-sqlite3` (and `@types/better-sqlite3` for TypeScript) |
| `@cronwatch/sdk/postgres` | `pg` (and `@types/pg` for TypeScript) |
| `@cronwatch/sdk/anthropic` | `@anthropic-ai/sdk` 0.115 or newer |

The store entry points' type declarations refer to the driver's types, so a TypeScript project using them without `@types/better-sqlite3` or `@types/pg` fails with TS7016 unless `skipLibCheck` is on. The package ships ESM and CommonJS, each with its own types.

## Ruby and Rails

The `cronwatch` gem is a port of the SDK, not a new design: it writes the same tables and sends the same alerts, so a Rails app and a Node service can share one database and one dashboard.

```ruby
class NightlyReportJob < ApplicationJob
  include Cronwatch::ActiveJob
  cronwatch schedule: "0 2 * * *", grace: "15m", expect: "Report written"

  def perform
    cronwatch.log("Report written")
  end
end
```

```bash
bundle add cronwatch
bin/rails generate cronwatch:install
bin/rails db:migrate
```

`gem "cronwatch"` in a Rails app loads the Rails integration, and `Cronwatch::Sidekiq` when Sidekiq is in the bundle. `bin/rails generate cronwatch:install` adds the migration and the initializer (which sets the ActiveRecord store) and prints the rest: schedule `Cronwatch::CheckJob` every five minutes (or `bin/rails cronwatch:check` from a crontab), and mount `Cronwatch::Web.new(Cronwatch.client)` in `config/routes.rb` for the dashboard (Rails autoloads it; outside Rails, `require "cronwatch/web"`). `schedule: :from_scheduler` reads a job's schedule from Solid Queue's or sidekiq-cron's config. Ruby 3.2 or newer; tested on Rails 7.2, 8.0 and 8.1. See [packages/ruby](packages/ruby), [cronwatch.dev/docs/rails](https://cronwatch.dev/docs/rails/) and [cronwatch.dev/docs/ruby](https://cronwatch.dev/docs/ruby/); the gem is on [RubyGems](https://rubygems.org/gems/cronwatch). The TypeScript SDK is the source of truth: `npm run conformance` generates cases in `conformance/` that the gem's tests replay.

## Why a library and not a service

A hosted monitor gives you an observer that is alive when your job is not. That is real, and it is the one thing a library cannot do: if your whole app is down, nothing inside it can alert (pair it with any uptime monitor for that case). Everything else, from a job that never fires to one that costs three times what it should, is caught from within, with your run history in your own database and nothing to sign up for.

## Development

Develop on Node 24 (`.nvmrc`); CI also runs Node 22, the oldest supported (better-sqlite3 13 needs it). Postgres tests run when `CRONWATCH_TEST_PG` points at a database.

```bash
npm ci
npm run check          # dash check, typecheck, tests
npm run build          # every package and the site
npm run dev --workspace site    # the site on http://localhost:4321, rebuilding on change
npm run check:packages # pack both packages and use them from a scratch project (after build)
npm run conformance    # regenerate conformance/ from the SDK, for the Ruby gem
```

The gem (Ruby 3.2 or newer), after `npm run build` so its Node compatibility tests can run:

```bash
cd packages/ruby
bundle install
bundle exec rake test
```

[Its README](packages/ruby/README.md#testing) has the rest: Postgres, each Rails series, the dashboard fixture and the MCP cross test.

`npm run check:dashes` fails on an em or en dash in any tracked text file; CI also checks the commit messages.

## Releasing

The SDK, the MCP server, the gem and the skill share one version. From a clean `main`:

```bash
npm run release -- 0.4.0 --dry-run   # show every change and command, write nothing
npm run release -- 0.4.0             # bump, regenerate, check, commit "Release 0.4.0", tag v0.4.0
```

It bumps every file listed at the top of `scripts/release.mjs`, refreshes `package-lock.json`, regenerates `conformance/` and the dashboard fixture, runs `npm run check`, the build, `npm run check:packages` and (with Ruby 3.2 or newer; `--skip-ruby` skips them) the gem's tests, then builds the gem and checks what it carries. It does not push or publish: it prints the `git push`, `npm publish` and `gem push` commands to run next (RubyGems spells a prerelease `0.4.0-beta.1` as `0.4.0.pre.beta.1` and refuses `+build` metadata, so the script does too), and `npm deprecate` lines for any `--deprecate <old>`. A new package under `packages/` needs a row in both of its tables (the file holding its version, and how it ships), or the script refuses to run.

## Deploying the site

Once CI passes on a push to `main`, `.github/workflows/deploy.yml` runs the deploy script on the server, which builds a release on the server beside the live one and switches a symlink only when the build checks out. `deploy/README.md` has the server layout, the one-time setup and the rollback command.

## License

MIT, see [LICENSE](LICENSE).
