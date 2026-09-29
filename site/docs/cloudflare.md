---
title: Cloudflare Workers
description: Cron Triggers, the D1 store, the check on a trigger of its own, the dashboard in fetch, and secrets with wrangler.
order: 3.391
group: More JavaScript platforms
---

# Cloudflare Workers

The shape on Workers: Cron Triggers call the Worker's `scheduled` handler, which runs your jobs and, on a trigger of its own, the check. The runs and state live in D1. The dashboard is served from `fetch`.

The core (`@cronwatch/sdk`) runs in the Workers runtime as it is. It imports nothing from Node and reads `process` only where there is one, so the `nodejs_compat` flag is not needed for it, the D1 store, or any alert channel.

```bash
npm install @cronwatch/sdk
npx wrangler d1 create cronwatch
```

## wrangler.toml

One D1 binding, and a Cron Trigger for each job plus one for the check. Cron Triggers run in UTC.

```toml
name = "reports"
main = "src/index.ts"
compatibility_date = "2025-09-01"

[[d1_databases]]
binding = "DB"
database_name = "cronwatch"
database_id = "<the id wrangler d1 create printed>"
migrations_dir = "migrations"

[triggers]
crons = ["0 2 * * *", "*/5 * * * *"]
```

## The tables

By default the store creates its three tables on first use with `CREATE TABLE IF NOT EXISTS`, once per isolate. To create them with a D1 migration instead, add this file and pass `createTables: false` to `d1()`:

```sql
-- migrations/0001_cronwatch.sql
CREATE TABLE IF NOT EXISTS cronwatch_jobs (
  name TEXT PRIMARY KEY,
  definition TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS cronwatch_runs (
  id TEXT PRIMARY KEY,
  job TEXT NOT NULL,
  status TEXT NOT NULL,
  started_at INTEGER NOT NULL,
  finished_at INTEGER,
  duration_ms INTEGER,
  error TEXT,
  output TEXT,
  metrics TEXT NOT NULL DEFAULT '{}',
  trigger TEXT NOT NULL DEFAULT 'run'
);
CREATE INDEX IF NOT EXISTS cronwatch_runs_job_started ON cronwatch_runs (job, started_at DESC);
CREATE INDEX IF NOT EXISTS cronwatch_runs_running ON cronwatch_runs (status) WHERE status = 'running';
CREATE TABLE IF NOT EXISTS cronwatch_state (
  job TEXT PRIMARY KEY,
  state TEXT NOT NULL
);
```

```bash
npx wrangler d1 migrations apply cronwatch --local
npx wrangler d1 migrations apply cronwatch --remote
```

These are the SQLite store's tables, byte for byte. With a `prefix`, replace `cronwatch_` in every name.

## The Worker

A Worker has no module-level `env`: bindings and secrets arrive with each invocation. So make the client inside the handler, from `env`, with a small function that also declares the jobs. That is cheap: making a client does no I/O, and it keeps no timers or connections. Everything that must last (runs, open conditions, queued alerts) is in D1, so nothing is lost between invocations. Do not keep a client at module level: an invocation's unfinished work (a job's queue of state updates, a check in progress) would carry into the next, and Workers does not let one invocation wait on another's I/O.

```ts
// src/index.ts
import { cronwatch } from "@cronwatch/sdk";
import { d1 } from "@cronwatch/sdk/d1";
import { slack } from "@cronwatch/sdk/slack";

interface Env {
  DB: D1Database;
  CRONWATCH_TOKEN: string;
  SLACK_WEBHOOK_URL: string;
}

function monitor(env: Env) {
  const cw = cronwatch({
    store: d1(env.DB),
    alerts: [slack({ webhookUrl: env.SLACK_WEBHOOK_URL })],
    defaults: { timezone: "UTC" },     // Cron Triggers run in UTC
  });
  const nightly = cw.job("nightly-report", { schedule: "0 2 * * *", grace: "15m", timeout: "10m" });
  return { cw, nightly };
}

export default {
  async scheduled(controller, env, ctx) {
    const { cw, nightly } = monitor(env);
    switch (controller.cron) {
      case "0 2 * * *":
        ctx.waitUntil(nightly.run(async (job) => {
          const rows = await buildReport(env);
          job.metric("rows", rows);
        }));
        break;
      case "*/5 * * * *":
        ctx.waitUntil(cw.check());
        break;
    }
  },

  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/cronwatch" || url.pathname.startsWith("/cronwatch/")) {
      return monitor(env).cw.routes({ token: env.CRONWATCH_TOKEN }).handler(request);
    }
    return new Response("Not found", { status: 404 });
  },
} satisfies ExportedHandler<Env>;
```

`D1Database` and `ExportedHandler` come from `wrangler types` (or `@cloudflare/workers-types`). The SDK does not need either: `d1()` takes anything with D1's `prepare` and `batch`.

**Jobs.** `job.run()` records the run and rethrows whatever the job throws, so a failure shows in the Worker's Cron Trigger log as well as in CronWatch. Keep the job's `schedule` the same as its trigger, so a trigger that never fires is noticed.

**The check.** Its own trigger, every five minutes here, calls `cw.check()` directly: no HTTP round trip, no secret. It marks missed and stuck runs, sends and retries alerts, and prunes old runs. A job declared in `monitor()` is written to the store on every invocation, so a job that has never run is still found missed.

**No start().** `cw.start()` checks on an interval, which needs a process that stays up. A Worker does nothing between invocations, and timers do not outlive the invocation that set them, so use the check trigger instead.

**The dashboard.** `cw.routes()` is a fetch handler, so it mounts in `fetch` under `/cronwatch` (change `basePath` to mount it elsewhere). Open `/cronwatch/?token=<CRONWATCH_TOKEN>` once and a cookie keeps the browser signed in. The MCP server reads the same routes.

## Secrets

Keep the token and the channel keys out of `wrangler.toml`:

```bash
npx wrangler secret put CRONWATCH_TOKEN
npx wrangler secret put SLACK_WEBHOOK_URL
npx wrangler secret put ANTHROPIC_API_KEY     # only with triage
```

For `wrangler dev`, put the same names in `.dev.vars` (and keep it out of git).

On Workers, pass every value from `env` yourself, as above. The defaults that read `process.env` (`CRONWATCH_TOKEN` for the routes, `CRON_SECRET` for `cronSecret`, `NODE_ENV` for the development token) find nothing without `nodejs_compat`, so the routes answer 503 until a token is passed, and there is no development token: set `CRONWATCH_TOKEN` in `.dev.vars` for local work too. `CRON_SECRET` matters only if you also run jobs over HTTP with `job.handler()`; then pass `cronSecret: env.CRON_SECRET`.

With `nodejs_compat` on, the Worker has a `process.env`, and Cloudflare fills it with the Worker's vars and secrets when the `nodejs_compat_populate_process_env` flag is set, which it is by default for a compatibility date of 2025-04-01 or later (see [Cloudflare's notes on `process`](https://developers.cloudflare.com/workers/runtime-apis/nodejs/process/)). Then those defaults find `CRONWATCH_TOKEN` and `CRON_SECRET` on their own, and a `NODE_ENV` var of `development` turns on the development token. Passing the values from `env`, as above, works either way, so the Worker does not depend on the flag.

## Trying it locally

```bash
npx wrangler dev --test-scheduled
curl "http://localhost:8787/__scheduled?cron=0+2+*+*+*"
curl "http://localhost:8787/__scheduled?cron=*/5+*+*+*+*"
```

Then open `http://localhost:8787/cronwatch/?token=<the token in .dev.vars>`.

## What differs on Workers

**Durations.** Inside a Worker the clock only moves while the Worker waits on I/O, so a job that is all CPU records a duration near zero. Durations of jobs that fetch, query or call APIs are what you would expect. Slow alerts are only as good as the durations they are measured from.

**Killed runs.** A run cut off by a Worker limit cannot report back. It stays `running` until a check finds it past the job's `timeout` and sends a stuck alert, the same as a serverless function killed mid-run. Set `timeout` a little above the longest the job may take.

**Channels.** Every channel uses only `fetch` and Web Crypto, so Slack, Discord, the signed webhook, the email, SMS and error tracker channels, and custom channels all run without `nodejs_compat`; put their keys in secrets. For triage, pass the key: `anthropic({ apiKey: env.ANTHROPIC_API_KEY })`.

**Stores.** The SQLite and Postgres stores are Node drivers; use D1. Pass `env.DB` itself, not a session from `withSession()`, so every read sees the last write: the store's conditional state writes depend on it. See [Stores](/docs/stores/#d1) for how the D1 store works.
