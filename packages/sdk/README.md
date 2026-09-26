# @cronwatch/sdk

Cron and scheduled-job monitoring that lives inside your app. Wrap a job once; every run is recorded in a database you already have, and you are told when a run is missed, fails, gets stuck, runs slow or goes over budget. No server to run, no account to make.

Docs: [cronwatch.dev/docs](https://cronwatch.dev/docs/)

```bash
npm install @cronwatch/sdk
npm install better-sqlite3                # or pg
npm install -D @types/better-sqlite3      # or @types/pg; TypeScript without skipLibCheck
```

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
  schedule: "0 2 * * *",     // cron, "@hourly", or "every 15m"
  timezone: "UTC",
  grace: "15m",              // how late a start may be before it is missed
  timeout: "30m",            // a run still going after this is stuck
  expect: "Report written",  // output must contain this, or the run failed
  budget: { cost: 2 },       // cost above 2 is over budget
});
```

```ts
// app/api/cron/nightly-report/route.ts
// A fetch-style handler (Next.js route, Hono, Bun). Checks Authorization: Bearer CRON_SECRET,
// and answers 503 without running when CRON_SECRET is unset outside development.
import { nightlyReport } from "@/lib/cronwatch";

export const GET = nightlyReport.handler(async (job) => {
  const report = await buildReport();
  job.log("Report written:", report.path);
  job.metric("cost", report.usdCost);
});
```

```ts
// app/cronwatch/[[...path]]/route.ts
// Dashboard and JSON API, behind CRONWATCH_TOKEN
import { cw } from "@/lib/cronwatch";

export const { GET, POST, DELETE } = cw.routes();
```

```ts
// Or wrap a plain function
await nightlyReport.run(async (job) => { /* ... */ });

// Missed and stuck runs are found by the check: on an interval, or a cron hitting /cronwatch/api/check
cw.start();
```

## What it catches

- **missed**: the schedule said a run was due and none started within the grace period
- **failed**: the function threw, the handler returned 4xx or 5xx, or the output did not satisfy `expect`
- **stuck**: a run started and never reported finishing within `timeout`
- **slow**: a successful run took longer than `maxDuration`, or twice the job's recent p95
- **over_budget**: a metric went above its `budget` ceiling, or three times its usual median
- **recovered**: a run succeeded after any of the above

Each condition alerts once when it opens, and is answered by one recovered message once a run succeeds again.

## Entry points

| Import | |
|---|---|
| `@cronwatch/sdk` | `cronwatch`, `memory`, `custom`, `consoleChannel`, `createRoutes`, types |
| `@cronwatch/sdk/sqlite` | `sqlite({ path })`, needs `better-sqlite3` (and `@types/better-sqlite3` in TypeScript) |
| `@cronwatch/sdk/postgres` | `postgres({ connectionString })`, needs `pg` (and `@types/pg` in TypeScript) |
| `@cronwatch/sdk/slack`, `/discord`, `/webhook` | alert channels |
| `@cronwatch/sdk/anthropic` | `anthropic()` triage: a short diagnosis on every alert except recoveries, needs `@anthropic-ai/sdk` |

Node 22 or newer. MIT.
