---
title: Servers and scripts
description: Long-running Node servers, node-cron, BullMQ, and plain scripts run from crontab.
order: 3
---

# Servers and scripts

## A long-running server

Any process that stays up can run the checker itself. Call `cw.start()` once at boot and `cw.stop()` on shutdown.

```ts
import { cw } from "./cronwatch.js";

cw.start("1m");
process.on("SIGTERM", () => { cw.stop(); });
```

The interval is unref'd, so it never keeps a process alive on its own.

## node-cron

Wrap the function you hand to the scheduler. The schedule string in the declaration should match the one you give node-cron, so a job the scheduler forgets to fire is still noticed.

```ts
import cron from "node-cron";
import { cw } from "./cronwatch.js";

const cleanup = cw.job("cleanup-uploads", { schedule: "*/30 * * * *", grace: "5m" });

cron.schedule("*/30 * * * *", () => {
  cleanup.run(async (job) => {
    const removed = await removeStaleUploads();
    job.metric("removed", removed);
  }).catch(() => { /* recorded and alerted already */ });
});
```

## BullMQ repeatable jobs

Wrap the processor. Use `every` intervals when the repeat is expressed that way.

```ts
import { Worker } from "bullmq";
import { cw } from "./cronwatch.js";

const reindex = cw.job("reindex-search", { schedule: "every 15m", timeout: "10m" });

new Worker("scheduled", async (bull) => {
  if (bull.name === "reindex-search") {
    return reindex.run(async (job) => {
      const count = await reindexAll();
      job.metric("documents", count);
    });
  }
});
```

## Plain scripts from crontab

A script run by crontab starts, does its work and exits, so nothing inside it is around to notice the run that never happened. Two crontab lines solve that: the job, and a check every few minutes.

```ts
// scripts/nightly-backup.ts
import { cw } from "../lib/cronwatch.js";

const backup = cw.job("nightly-backup", { schedule: "0 3 * * *", grace: "20m", expect: "uploaded" });

await backup.run(async (job) => {
  const key = await uploadBackup();
  job.log("uploaded", key);
});
await cw.close();
```

```ts
// scripts/cronwatch-check.ts
import { cw } from "../lib/cronwatch.js";
import "../scripts/jobs.js";   // a module that declares every job, so never-ran jobs are known

const result = await cw.check();
console.log(`${result.jobs.length} jobs, ${result.alerts.length} alerts`);
await cw.close();
```

```
0 3 * * *    cd /srv/app && node dist/scripts/nightly-backup.js
*/5 * * * *  cd /srv/app && node dist/scripts/cronwatch-check.js
```

Keep every `cw.job()` declaration in one module the check script imports. A job is only known to the store once it has been declared in a process that ran a check or a run, so a job that has never run and is not declared in the check process cannot be reported as missing.

## Hono, Bun, Deno and friends

`handler()` and `routes()` speak the fetch standard: they take a `Request` and return a `Response`. Mount them wherever a fetch handler goes.

```ts
import { Hono } from "hono";
import { cw } from "./cronwatch.js";

const hourly = cw.job("hourly-sync", { schedule: "@hourly" });
const app = new Hono();
const routes = cw.routes({ basePath: "/cronwatch" });
app.all("/cronwatch/*", (c) => routes.handler(c.req.raw));
app.get("/jobs/hourly", (c) => hourly.handler(async () => { /* ... */ })(c.req.raw));
```

Behind a proxy that terminates TLS, `@hono/node-server` builds `c.req.raw` from the connection it sees, so its URL says `http://` and the internal host, and the dashboard refuses its own forms as cross-site. Tell the routes the public origin:

```ts
const routes = cw.routes({ basePath: "/cronwatch", origin: "https://app.example.com" });
// or, when the proxy sets (and overwrites) X-Forwarded-Proto and X-Forwarded-Host:
const routes = cw.routes({ basePath: "/cronwatch", trustProxy: true });
```

See [behind a proxy](/docs/dashboard/#behind-a-proxy).

A handler requires `Authorization: Bearer <CRON_SECRET>`. With no `CRON_SECRET` set (an empty value counts as unset) it answers 503 and runs nothing, unless `NODE_ENV` is `development` or `test`. For an endpoint that is protected some other way, say so explicitly with `secret: null`:

```ts
app.post("/internal/reindex", (c) => reindex.handler(async () => { /* ... */ }, { secret: null })(c.req.raw));
```

Without a secret the response never includes the job's error text, only its status.

The routes want `CRONWATCH_TOKEN` in the same way. Without it, while `NODE_ENV` is `development` or `test`, they make a token and print a sign-in link to the process's log on their first request (`[cronwatch] CRONWATCH_TOKEN is not set, so this development server made a token for the dashboard. Sign in: http://localhost:3000/cronwatch/?token=...`); open it once. With `NODE_ENV` anything else they answer 503 until a token is set. See [access](/docs/dashboard/#access).

The stores use Node drivers (`better-sqlite3`, `pg`), so the process needs Node compatibility. `better-sqlite3` crashes in Bun; on Bun, use the Postgres store.

## Express, Koa and plain Node servers

Express, Connect, Koa, NestJS and `http.createServer` hand you Node's `IncomingMessage` and `ServerResponse` rather than a `Request`. `@cronwatch/sdk/node` converts between the two, for the routes and for any job `handler()`:

```ts
import { createServer } from "node:http";
import { toNodeHandler } from "@cronwatch/sdk/node";
import { cw } from "./cronwatch.js";

const routes = cw.routes({ basePath: "/cronwatch" });
createServer(toNodeHandler(routes.handler)).listen(3000);
```

In Express (4 or 5), mount it at the path. The adapter reads `req.originalUrl`, so the routes still see the full path:

```ts
import express from "express";
import { toNodeHandler } from "@cronwatch/sdk/node";

const app = express();
app.use(express.json());
app.use("/cronwatch", toNodeHandler(routes.handler));
```

Or give it a `basePath` and put it anywhere in the chain: requests at that path or under it are answered, and every other request goes to `next()` (on a plain server, with no `next`, they get a 404).

```ts
app.use(toNodeHandler(routes.handler, { basePath: "/cronwatch" }));
```

In Koa, `toKoaMiddleware` takes the same options, sets `ctx.respond = false` on the requests it answers, and calls `next()` for the rest:

```ts
import Koa from "koa";
import { toKoaMiddleware } from "@cronwatch/sdk/node";

const app = new Koa();
app.use(toKoaMiddleware(routes.handler, { basePath: "/cronwatch" }));
```

The request body, for anything but `GET` and `HEAD`, comes from the first of these that exists:

1. `req.rawBody` (Firebase, NestJS with `rawBody: true`), or `ctx.request.rawBody` in Koa;
2. the request stream, when no body parser has read it, passed on as a stream;
3. a body a parser decoded (`req.body` from `express.json()` or `express.urlencoded()`, `ctx.request.body` in Koa), encoded again as JSON or as a urlencoded form to match its `Content-Type`.

A parsed body of any other type, multipart for instance, cannot be rebuilt and is dropped. Mounting the adapter before the body parsers avoids the question.

The response is written with its status, every header (each `Set-Cookie` on its own line) and its body, streamed. An error the fetch handler throws goes to `next(error)` in Express and is thrown on to Koa; a plain server answers 500.

The request URL is built from the `Host` header and the connection's scheme. Behind a proxy that terminates TLS, pass `trustProxy: true` to use the first `X-Forwarded-Proto` and `X-Forwarded-Host` instead, but only when the proxy sets or overwrites both, since a client can send them too. Setting `origin` on the routes does the same job without trusting any header; see [behind a proxy](/docs/dashboard/#behind-a-proxy).

`toRequest(req, options?)` and `writeResponse(res, response)` are exported as well, for a framework none of the above fits.
