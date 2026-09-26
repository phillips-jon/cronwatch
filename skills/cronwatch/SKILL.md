---
name: cronwatch
description: This skill should be used when the user asks to "monitor a cron job", "add CronWatch", "watch this scheduled job", "alert me if this job fails or doesn't run", "check on my cron jobs", "why did the nightly job fail", or mentions @cronwatch/sdk, cronwatch.dev or the cronwatch MCP server.
version: 0.1.0
---

# CronWatch

CronWatch is a library, not a service: `@cronwatch/sdk` records every run of a scheduled job inside the app that runs it, and alerts when a run is missed, fails, gets stuck, runs slow or goes over budget. The MCP server `@cronwatch/mcp` reads the same data so an agent can ask what failed and why.

## Adding monitoring to a job

1. Find where the job runs: a Vercel cron route handler, a `node-cron` or BullMQ job, a GitHub Actions schedule calling an endpoint, or a plain script.
2. Install the SDK and pick a store the app already has: `@cronwatch/sdk/sqlite` for one server, `@cronwatch/sdk/postgres` for Vercel, Neon, Supabase or Railway.
3. Create one client in a shared module and declare each job once with `cw.job(name, options)`. Give it the real schedule (cron expression, `@hourly`, or `every 15m`) and a `timezone` when the scheduler runs in UTC (Vercel and GitHub Actions do).
4. Wrap the work: `job.handler(fn)` for a route, `job.run(fn)` for a function. Log what matters with `job.log()` and report numbers with `job.metric()` (tokens, cost, rows).
5. Mount the dashboard and JSON API with `cw.routes()` and set `CRONWATCH_TOKEN`.
6. Make sure something calls `cw.check()`: `cw.start()` once in a long-running process, or a cron hitting `GET <mount>/api/check` with the bearer token every few minutes. Without it, missed and stuck runs are never noticed.
7. Add an alert channel (`slack`, `discord`, `webhook`) and, if wanted, AI triage with `anthropic()`.

Ask before adding dependencies or changing the app's store. Keep job names stable: they are the key everything hangs off.

```ts
import { cronwatch } from "@cronwatch/sdk";
import { sqlite } from "@cronwatch/sdk/sqlite";
import { slack } from "@cronwatch/sdk/slack";

export const cw = cronwatch({
  store: sqlite({ path: "./data/cronwatch.db" }),
  alerts: [slack({ webhookUrl: process.env.SLACK_WEBHOOK_URL! })],
});

export const nightlyReport = cw.job("nightly-report", {
  schedule: "0 2 * * *", timezone: "UTC", grace: "15m", timeout: "30m", expect: "Report written",
});
```

## Investigating a failure

With the MCP server configured (`claude mcp add cronwatch -e CRONWATCH_URL=... -e CRONWATCH_TOKEN=... -- npx -y @cronwatch/mcp`):

1. `list_jobs` to see what is unhealthy.
2. `get_job` for the failing one: read the error, the output tail and the metrics of the last runs before changing code.
3. Fix the cause in the app, not the monitor. Use `silence_job` only while a known fix is in progress.
4. After deploying, `run_check` and `get_job` again to confirm a clean run.

## What the conditions mean

- missed: the schedule said a run was due and none started within the grace period.
- failed: the function threw, the handler returned 4xx/5xx, or the output did not satisfy `expect`.
- stuck: a run started and never reported finishing within `timeout`. Often a killed process.
- slow: a successful run took longer than `maxDuration`, or more than twice the recent p95.
- over_budget: a metric went above its `budget` ceiling, or three times the recent median.
- recovered: a run succeeded after any of the above.

Docs: https://cronwatch.dev/docs
