---
title: Strapi
description: Cron tasks in config/cron-tasks wrapped with job.run(), the check from bootstrap, and the dashboard as a global middleware.
order: 3.34
group: More JavaScript platforms
---

# Strapi

Strapi runs cron tasks inside the server process, from `config/cron-tasks.ts`. The server stays up, so it can run the check as well.

## The client

```ts
// src/cronwatch.ts
import { cronwatch } from "@cronwatch/sdk";
import { postgres } from "@cronwatch/sdk/postgres";
import { slack } from "@cronwatch/sdk/slack";

export const cw = cronwatch({
  store: postgres({ connectionString: process.env.DATABASE_URL }),
  alerts: [slack({ webhookUrl: process.env.SLACK_WEBHOOK_URL! })],
});

export const unpublishExpired = cw.job("unpublish-expired", {
  schedule: "0 */15 * * * *",
  timezone: "Europe/Berlin",
  grace: "5m",
  timeout: "10m",
});
```

The store can live in the database Strapi already uses: the tables are prefixed `cronwatch_` and do not touch Strapi's. With Strapi on SQLite, `sqlite({ path: "./data/cronwatch.db" })` from `@cronwatch/sdk/sqlite` works as long as the disk persists across deploys.

## A cron task

Strapi's rules take an optional seconds field first, and CronWatch reads six fields the same way, so the expression can be copied as is. Give the job the same zone as the task's `tz`; without `tz` both read the server's zone.

```ts
// config/cron-tasks.ts
import type { Core } from "@strapi/strapi";
import { unpublishExpired } from "../src/cronwatch";

export default {
  unpublishExpired: {
    task: async ({ strapi }: { strapi: Core.Strapi }) => {
      await unpublishExpired
        .run(async (job) => {
          const offers = strapi.documents("api::offer.offer");
          const expired = await offers.findMany({
            filters: { expiresAt: { $lt: new Date().toISOString() } },
            status: "published",
          });
          for (const offer of expired) await offers.unpublish({ documentId: offer.documentId });
          job.metric("unpublished", expired.length);
        })
        .catch(() => { /* recorded and alerted already */ });
    },
    options: { rule: "0 */15 * * * *", tz: "Europe/Berlin" },
  },
};
```

`run()` rethrows what the task throws; the `.catch` keeps that from becoming an unhandled rejection once it has been recorded. Turn the tasks on in `config/server.ts`: import them (`import cronTasks from "./cron-tasks";`) and add `cron: { enabled: true, tasks: cronTasks }` to the configuration it returns.

Tasks added at runtime with `strapi.cron.add()` can be wrapped the same way; declare their jobs at startup so a task that never gets added is noticed.

## The check

Start it in `bootstrap` and close the client in `destroy`:

```ts
// src/index.ts
import { cw } from "./cronwatch";

export default {
  register() {},
  bootstrap() {
    cw.startChecking("1m");
  },
  async destroy() {
    await cw.close();
  },
};
```

Every Strapi instance runs every cron task. With more than one instance, all their runs land in the shared store; to have the work happen once, enable cron on one instance only, and run the check there.

## The dashboard

Strapi's HTTP server is Koa. A global middleware made with `toKoaMiddleware` from `@cronwatch/sdk/node` hands `/cronwatch` and everything under it to the routes, before Strapi's body parser reads the request, and passes every other path on (see [Express, Koa, and plain Node servers](/docs/node/#express-koa-and-plain-node-servers)).

```ts
// src/middlewares/cronwatch.ts
import { toKoaMiddleware } from "@cronwatch/sdk/node";
import { cw } from "../cronwatch";

const routes = cw.routes({ basePath: "/cronwatch" });

export default () => toKoaMiddleware(routes.handler, { basePath: "/cronwatch" });
```

It sets `ctx.respond = false` and writes the response itself, so Koa leaves it alone.

Register it as `global::cronwatch` in `config/middlewares.ts`, after `strapi::errors` and before `strapi::security` and `strapi::body`:

```ts
// config/middlewares.ts
export default [
  "strapi::logger",
  "strapi::errors",
  "global::cronwatch",
  "strapi::security",
  "strapi::cors",
  "strapi::poweredBy",
  "strapi::query",
  "strapi::body",
  "strapi::session",
  "strapi::favicon",
  "strapi::public",
];
```

The dashboard sends its own security headers, which is why it sits before `strapi::security`. Set `CRONWATCH_TOKEN` and open `/cronwatch?token=<it>` once. Behind a proxy that terminates TLS, the dashboard's forms are refused as cross-site until the routes know the public origin: pass `origin: "https://cms.example.com"` to `cw.routes()`, or `trustProxy: true` to `toKoaMiddleware` when the proxy sets `X-Forwarded-Proto` and `X-Forwarded-Host`. See [behind a proxy](/docs/dashboard/#behind-a-proxy).
