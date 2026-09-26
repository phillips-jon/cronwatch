---
title: Next.js and Vercel
description: Vercel cron, route handlers, the Postgres store, the check cron and the Node runtime.
order: 2
---

# Next.js and Vercel

The common shape: Vercel's cron hits a route handler on a schedule, and the app runs on serverless functions with no disk.

## The pieces

**A Postgres store.** Serverless functions have no persistent filesystem, so use `@cronwatch/sdk/postgres` with the database you already have (Neon, Supabase, Vercel Postgres). It creates three tables prefixed `cronwatch_` on first use.

```ts
// lib/cronwatch.ts
import { cronwatch } from "@cronwatch/sdk";
import { postgres } from "@cronwatch/sdk/postgres";
import { slack } from "@cronwatch/sdk/slack";

export const cw = cronwatch({
  store: postgres({ connectionString: process.env.DATABASE_URL }),
  alerts: [slack({ webhookUrl: process.env.SLACK_WEBHOOK_URL! })],
  defaults: { timezone: "UTC" },      // Vercel crons run in UTC
});

export const digest = cw.job("daily-digest", { schedule: "0 6 * * *", grace: "10m", timeout: "5m" });
```

**The cron entries.** Vercel calls each path with `Authorization: Bearer <CRON_SECRET>`. Add one entry for the check.

```json
{
  "crons": [
    { "path": "/api/cron/daily-digest", "schedule": "0 6 * * *" },
    { "path": "/cronwatch/api/check",   "schedule": "*/10 * * * *" }
  ]
}
```

**The job route.** `handler()` checks the bearer secret itself, so the route needs nothing else.

```ts
// app/api/cron/daily-digest/route.ts
import { digest } from "@/lib/cronwatch";

export const runtime = "nodejs";     // the stores are Node drivers, not edge
export const maxDuration = 300;

export const GET = digest.handler(async (job) => {
  const sent = await sendDigest();
  job.metric("emails", sent);
});
```

**The dashboard and API.**

```ts
// app/cronwatch/[[...path]]/route.ts
import { cw } from "@/lib/cronwatch";
export const runtime = "nodejs";
export const { GET, POST, DELETE } = cw.routes();
```

Set `CRONWATCH_TOKEN` in the project's environment variables. The check endpoint accepts either that token or `CRON_SECRET`, which is why the cron entry above works without sharing the dashboard token.

## Timeouts and stuck runs

When a function hits Vercel's execution limit, the run is killed before it can report. It stays `running` in the store until the next check passes the job's `timeout`, at which point it is marked `timeout` and a stuck alert goes out. Set `timeout` a little above the function's `maxDuration` so the alert is prompt but never premature.

## Self-hosted Next.js

With `next start` or the standalone server, the process is long-lived, so start the checker from `instrumentation.ts` instead of a cron entry:

```ts
// instrumentation.ts
export async function register() {
  if (process.env.NEXT_RUNTIME === "nodejs") {
    const { cw } = await import("./lib/cronwatch");
    cw.start();
  }
}
```

SQLite is fine here. Keep the database outside the build output and inside whatever directory the process may write to.

## Development

`next dev` reloads modules, and each reload creates a fresh client. That is harmless: `cw.job()` declarations are idempotent and the store is shared. Leave `CRONWATCH_TOKEN` unset locally and the routes are open.
