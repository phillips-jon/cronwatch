---
title: SvelteKit
description: A +server.ts endpoint for each job, the dashboard in a catch-all route, and the check on adapter-node or a platform cron.
order: 3.3
group: More platforms
---

# SvelteKit

SvelteKit has no scheduler of its own. Something outside calls an endpoint on a schedule: Vercel cron, a Netlify scheduled function, GitHub Actions, or crontab running `curl`. Each job is a `+server.ts` endpoint wrapped with `handler()`, and the dashboard is one catch-all endpoint.

## The client

Keep it under `src/lib/server` so SvelteKit never lets it reach the browser.

```ts
// src/lib/server/cronwatch.ts
import { cronwatch } from "@cronwatch/sdk";
import { postgres } from "@cronwatch/sdk/postgres";
import { slack } from "@cronwatch/sdk/slack";

export const cw = cronwatch({
  store: postgres({ connectionString: process.env.DATABASE_URL }),
  alerts: [slack({ webhookUrl: process.env.SLACK_WEBHOOK_URL! })],
  defaults: { timezone: "UTC" },
});

export const digest = cw.job("daily-digest", { schedule: "0 6 * * *", grace: "10m", timeout: "5m" });
```

Which store depends on the adapter. On `adapter-vercel` or `adapter-netlify` there is no disk, so use Postgres. On `adapter-node` with a persistent volume, SQLite works (`sqlite({ path: "./data/cronwatch.db" })`, from `@cronwatch/sdk/sqlite`). The stores are Node drivers, so the server code must run on Node.

The SDK reads `CRON_SECRET`, `CRONWATCH_TOKEN` and `DATABASE_URL` from `process.env`, which every Node adapter populates at runtime. To pass values from `$env/dynamic/private` instead, give them to `cronwatch({ cronSecret })`, `cw.routes({ token })` and `postgres({ connectionString })`.

## A job endpoint

```ts
// src/routes/api/cron/daily-digest/+server.ts
import { digest } from "$lib/server/cronwatch";
import type { RequestHandler } from "./$types";

const run = digest.handler(async (job) => {
  const sent = await sendDigest();
  job.metric("emails", sent);
});

export const GET: RequestHandler = ({ request }) => run(request);
```

`handler()` checks `Authorization: Bearer <CRON_SECRET>`, runs the function, records the run and answers 200 or 500. Point the platform's cron at the path. On Vercel that is `vercel.json`, whose crons run in UTC, the reason for `timezone: "UTC"` above:

```json
{
  "crons": [
    { "path": "/api/cron/daily-digest", "schedule": "0 6 * * *" },
    { "path": "/cronwatch/api/check",   "schedule": "*/10 * * * *" }
  ]
}
```

## The dashboard

A rest parameter matches `/cronwatch` itself as well as everything under it, so one file serves the whole dashboard and API.

```ts
// src/routes/cronwatch/[...path]/+server.ts
import { cw } from "$lib/server/cronwatch";
import type { RequestHandler } from "./$types";

const routes = cw.routes({ basePath: "/cronwatch" });

export const GET: RequestHandler = ({ request }) => routes.handler(request);
export const POST = GET;
export const DELETE = GET;
```

Set `CRONWATCH_TOKEN` and open `/cronwatch?token=<it>` once. SvelteKit redirects `/cronwatch/` to `/cronwatch`, which is harmless here.

The dashboard's forms post back to the same origin and CronWatch refuses cross-site posts, so the request URL SvelteKit builds must have the public origin. On `adapter-node` behind a proxy, set `ORIGIN` (or `PROTOCOL_HEADER` and `HOST_HEADER`) as the adapter's docs describe; SvelteKit's own CSRF check needs the same. Setting the adapter's `ORIGIN` is the fix for both; the routes' `origin` option ([behind a proxy](/docs/dashboard/#behind-a-proxy)) would only cover CronWatch's check.

## Where the check runs

On `adapter-node` the server stays up, so it can run the check itself. The `init` hook runs once before the first request:

```ts
// src/hooks.server.ts
import type { ServerInit } from "@sveltejs/kit";
import { cw } from "$lib/server/cronwatch";

export const init: ServerInit = () => {
  cw.start("1m");
};
```

On serverless adapters, leave that out and let the platform cron hit `/cronwatch/api/check` with `CRON_SECRET` as the bearer, as in the `vercel.json` above. The check endpoint accepts the cron secret, so the cron never needs the dashboard token.

## Limits that matter

A function killed by the platform's time limit cannot record its own end. The run stays `running` until a check passes the job's `timeout`, then it is marked stuck. Set `timeout` a little above the function's maximum duration.
