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
  timeout: "30m",            // a run still going after this is stuck (maxDuration: a finished run longer than it is slow)
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
cw.startChecking();
```

## What it catches

- **missed**: the schedule said a run was due and none started within the grace period
- **failed**: the function threw, the handler returned 4xx or 5xx, or the output did not satisfy `expect`
- **stuck**: a run started and never reported finishing within `timeout`
- **slow**: a successful run took longer than `maxDuration`, or twice the job's recent p95
- **over_budget**: on a successful run, a metric went above its `budget` ceiling, or three times its usual median
- **recovered**: a successful run left nothing open; one message names everything that was

Each condition alerts once when it opens. When a successful run leaves nothing open, one recovered message names everything that closed.

An `expect` RegExp runs in your process on the runtime's own engine and, like an `expect` function, has no time limit. A pattern with unbounded repeats that can match the same text (`/\n*\n*x/`, `/(a+)+b/`, `/.*x/`) can take seconds on a long output that does not match: anchor it, avoid a repeat next to or inside another over the same characters, or use a plain string. See [expect rules](https://cronwatch.dev/docs/conditions/#expect-rules).

## Entry points

| Import | |
|---|---|
| `@cronwatch/sdk` | `cronwatch`, `Cronwatch`, `memory`, `custom`, `consoleChannel`, types; the dashboard is `cw.routes()` |
| `@cronwatch/sdk/sqlite` | `sqlite({ path })`, needs `better-sqlite3` (and `@types/better-sqlite3` in TypeScript) |
| `@cronwatch/sdk/postgres` | `postgres({ connectionString })`, needs `pg` (and `@types/pg` in TypeScript) |
| `@cronwatch/sdk/d1` | `d1(env.DB)`, the Cloudflare D1 store; needs nothing |
| `@cronwatch/sdk/pg-cron` | `pgCron(pool)`, a source that reads pg_cron jobs (Supabase Cron included) from Postgres on every check; pass it in `sources` |
| `@cronwatch/sdk/node` | `toNodeHandler`, `toKoaMiddleware`, `toRequest`, `writeResponse`: fetch handlers on `http.createServer`, Express, Connect, NestJS and Koa |
| `@cronwatch/sdk/slack`, `/discord`, `/webhook` | chat and signed webhook alert channels; `/webhook` also has `signature(secret, body)` for a receiver |
| `@cronwatch/sdk/resend`, `/postmark`, `/sendgrid`, `/mailgun`, `/ses` | email alert channels |
| `@cronwatch/sdk/twilio` | SMS alerts |
| `@cronwatch/sdk/sentry`, `/honeybadger`, `/datadog`, `/rollbar`, `/bugsnag`, `/newrelic` | alerts as events in an error tracker |
| `@cronwatch/sdk/anthropic` | `anthropic()` triage: a short diagnosis on every alert except recoveries, needs `@anthropic-ai/sdk` |

The core, `/d1`, `/pg-cron` and every channel use only `fetch` and Web Crypto, so they run on Node 22 or newer, Cloudflare Workers, Deno and Bun. The SQLite and Postgres stores and `/node` need Node 22 or newer. MIT.
