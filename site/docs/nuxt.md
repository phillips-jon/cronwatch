---
title: Nuxt and Nitro
description: Nitro scheduled tasks wrapped with job.run(), a Nitro plugin for the check, and the dashboard as a server route.
order: 3.31
group: More platforms
---

# Nuxt and Nitro

Nitro, the server under Nuxt, can run tasks on a cron schedule. On the Node presets (`node-server`, `bun`, `deno-server`, and `nuxt dev`) it schedules them itself, inside the server process, so the server can run the check too. Tasks are still experimental in Nitro 2, which Nuxt uses, so they need a flag.

## The config

```ts
// nuxt.config.ts
export default defineNuxtConfig({
  nitro: {
    experimental: { tasks: true },
    scheduledTasks: {
      "0 * * * *": ["cleanup:sessions"],
    },
  },
});
```

For plain Nitro, the same two keys go in `nitro.config.ts`.

## The client

Files in `server/utils` are imported automatically everywhere under `server/`.

```ts
// server/utils/cronwatch.ts
import { cronwatch } from "@cronwatch/sdk";
import { sqlite } from "@cronwatch/sdk/sqlite";
import { slack } from "@cronwatch/sdk/slack";

export const cw = cronwatch({
  store: sqlite({ path: "./data/cronwatch.db" }),
  alerts: [slack({ webhookUrl: process.env.SLACK_WEBHOOK_URL! })],
});

export const sessionCleanup = cw.job("cleanup-sessions", { schedule: "0 * * * *", grace: "5m", timeout: "10m" });
```

SQLite suits a long-running server with a disk that survives deploys. Keep the file outside `.output`, which each build replaces. On a host without a persistent disk, use `postgres()` from `@cronwatch/sdk/postgres`.

Nitro schedules with croner and passes no time zone, so a cron expression is read in the server's local time. CronWatch reads a job without `timezone` the same way, so leave `timezone` unset and the two agree. If you set one, run the server with the same `TZ`.

## A task

The task's name comes from its path: `server/tasks/cleanup/sessions.ts` is `cleanup:sessions`. Wrap the body in `run()` and return what it returns.

```ts
// server/tasks/cleanup/sessions.ts
export default defineTask({
  meta: { name: "cleanup:sessions", description: "Delete expired sessions" },
  async run() {
    const removed = await sessionCleanup.run(async (job) => {
      const count = await deleteExpiredSessions();
      job.metric("removed", count);
      return count;
    });
    return { result: removed };
  },
});
```

A failed run rethrows, so Nitro logs `Error while running scheduled task` as it would without CronWatch; the failure has already been recorded and alerted.

Nitro runs at most one instance of a task at a time in each server process. A fire that arrives while the previous run is still going joins that run instead of starting another, so no new run is recorded. For a cron job that is reported as missed once the grace passes, which is what happened: the slot came and went with nothing new started. Give a slow task a `timeout` shorter than its interval, or a longer `grace`.

## The check

A Nitro plugin starts the check when the server boots and closes the client when it shuts down.

```ts
// server/plugins/cronwatch.ts
export default defineNitroPlugin((nitroApp) => {
  cw.start("1m");
  nitroApp.hooks.hook("close", () => cw.close());
});
```

Several server instances sharing one Postgres store would each run every scheduled task and each check. Every run is recorded and conditions still open once, but queued alerts can be retried twice; see [several instances](/docs/limits/#several-instances).

## The dashboard

A catch-all server route serves the dashboard and API. The `[...path]` route does not match `/cronwatch` itself, so an `index.ts` beside it re-exports the same handler.

```ts
// server/routes/cronwatch/[...path].ts
const routes = cw.routes({ basePath: "/cronwatch" });

export default defineEventHandler((event) => routes.handler(toWebRequest(event)));
```

```ts
// server/routes/cronwatch/index.ts
export { default } from "./[...path]";
```

`defineEventHandler` and `toWebRequest` come from h3 and are auto-imported in Nuxt. Set `CRONWATCH_TOKEN` and open `/cronwatch?token=<it>` once.

## Serverless presets

Off the Node presets, what Nitro does with `scheduledTasks` depends on the preset and on the Nitro version. This is how it stood at the time of writing, for Nitro 2.13 (what Nuxt 4 uses) and the Nitro 3 beta; check [Nitro's tasks page](https://nitro.build/docs/tasks) for your version.

- **Cloudflare Workers (`cloudflare_module`).** Nitro 2 runs the tasks whose cron matches when a Cron Trigger calls the Worker's `scheduled` handler, but it does not declare the triggers: list the same expressions under `triggers.crons` in your wrangler config yourself. Nitro 3 writes them into the wrangler config for you.
- **Vercel.** Nitro 2 does nothing with `scheduledTasks` there. Nitro 3 turns them into Vercel Cron Jobs that call `/_vercel/cron`; set `CRON_SECRET` in the project, since without it anyone who knows that route can start the tasks (see [Nitro's Vercel page](https://nitro.build/deploy/providers/vercel)). On the Hobby plan Vercel runs a cron at most once a day; see [Next.js and Vercel](/docs/nextjs/#on-the-hobby-plan).
- **Other serverless presets** (Netlify, AWS Lambda and the like) do not run them.

Where Nitro does run the tasks, the task above records its runs as it does on a server. Two things still change, because nothing runs between requests: the plugin's `cw.start()` never gets to check, so have the platform's scheduler call `/cronwatch/api/check` with `CRON_SECRET` as the bearer and drop the plugin; and there is no disk for SQLite, so use the Postgres store, or on Cloudflare the D1 store (see [Cloudflare Workers](/docs/cloudflare/)).

Where Nitro does not run them, trigger the job from the platform's scheduler instead. Put it in a server route wrapped with `handler()`, which is fetch-style:

```ts
// server/routes/api/cron/cleanup-sessions.get.ts
const run = sessionCleanup.handler(async (job) => {
  job.metric("removed", await deleteExpiredSessions());
});

export default defineEventHandler((event) => run(toWebRequest(event)));
```

Point the platform cron at it and at `/cronwatch/api/check` with `CRON_SECRET` as the bearer, drop the plugin, and use the Postgres store.
