---
title: React Router and Remix
description: Resource routes for job endpoints and the dashboard, in React Router framework mode and Remix 2.
order: 3.32
group: More JavaScript platforms
---

# React Router and Remix

A resource route is a route module with a `loader` or `action` and no component. Its loader and action get the fetch `Request` and may return a `Response`, which is all `handler()` and `routes()` need. Jobs are endpoints called by a scheduler outside the app, and the dashboard is one splat route.

## The client

The `.server` suffix keeps the module out of the browser bundle.

```ts
// app/lib/cronwatch.server.ts
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

Postgres for serverless hosts; SQLite (`@cronwatch/sdk/sqlite`) is fine for a long-running server with a persistent disk. `timezone: "UTC"` matches Vercel's crons; for crontab or another scheduler, use its zone.

## Routes

In React Router framework mode, add both routes to `app/routes.ts`:

```ts
// app/routes.ts
import { type RouteConfig, route } from "@react-router/dev/routes";

export default [
  // ...your other routes
  route("api/cron/daily-digest", "routes/api.cron.daily-digest.ts"),
  route("cronwatch/*", "routes/cronwatch.ts"),
] satisfies RouteConfig;
```

A splat matches the path with nothing after it too, so `cronwatch/*` serves `/cronwatch` and everything below it.

## A job endpoint

```ts
// app/routes/api.cron.daily-digest.ts
import { digest } from "~/lib/cronwatch.server";
import type { Route } from "./+types/api.cron.daily-digest";

const run = digest.handler(async (job) => {
  const sent = await sendDigest();
  job.metric("emails", sent);
});

export const loader = ({ request }: Route.LoaderArgs) => run(request);
```

The scheduler sends `GET /api/cron/daily-digest` with `Authorization: Bearer <CRON_SECRET>`. The handler checks it, records the run, and answers 200 or 500. Use `action` instead of `loader` if your scheduler sends POST.

## The dashboard

```ts
// app/routes/cronwatch.ts
import { cw } from "~/lib/cronwatch.server";
import type { Route } from "./+types/cronwatch";

const routes = cw.routes({ basePath: "/cronwatch" });

export const loader = ({ request }: Route.LoaderArgs) => routes.handler(request);
export const action = ({ request }: Route.ActionArgs) => routes.handler(request);
```

The loader serves the pages and the JSON API; the action takes the dashboard's form posts and API writes. Set `CRONWATCH_TOKEN` and open `/cronwatch?token=<it>` once.

## Remix 2

The same modules work in Remix 2 with its file routes and argument types. The splat file `cronwatch.$.ts` matches `/cronwatch` too.

```ts
// app/routes/cronwatch.$.ts
import type { ActionFunctionArgs, LoaderFunctionArgs } from "@remix-run/node";
import { cw } from "~/lib/cronwatch.server";

const routes = cw.routes({ basePath: "/cronwatch" });

export const loader = ({ request }: LoaderFunctionArgs) => routes.handler(request);
export const action = ({ request }: ActionFunctionArgs) => routes.handler(request);
```

A job endpoint is `app/routes/api.cron.daily-digest.ts` with a loader like the one above.

## Where the check runs

On a serverless host, add a cron for `/cronwatch/api/check`, sent with `CRON_SECRET` as the bearer; the check endpoint accepts the cron secret as well as the dashboard token.

On a long-running server (`react-router-serve`, or your own Express server), call `cw.startChecking()` once when the server starts. In a custom server, that is the file that calls `listen()`; import the client there. With `react-router-serve` there is no such file, so a cron hitting the check endpoint is the simpler route there too.

## Limits that matter

When a platform kills a function at its time limit, the run cannot record its end. It is marked stuck by the first check after its `timeout`, so set `timeout` a little above the function's maximum duration.
