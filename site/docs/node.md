---
title: Node servers and scripts
description: Long-running Node servers, node-cron, BullMQ, and plain scripts run from crontab.
order: 3
---

# Node servers and scripts

## A long-running server

Any process that stays up can run the checker itself. Call `cw.start()` once at boot and `cw.stop()` on shutdown.

```ts
import { cw } from "./cronwatch.js";

cw.start("1m");
process.on("SIGTERM", () => { cw.stop(); });
```

The first check runs about a second after `start()`, then one every interval. The interval is held between 5 seconds and about 24.8 days (the longest delay a timer keeps), and it is unref'd, so it never keeps a process alive on its own.

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
// lib/jobs.ts: every job, declared once
import { cw } from "./cronwatch.js";

export const backup = cw.job("nightly-backup", { schedule: "0 3 * * *", grace: "20m", expect: "uploaded" });
export const digest = cw.job("weekly-digest", { schedule: "0 8 * * 1" });
```

```ts
// scripts/nightly-backup.ts
import { cw } from "../lib/cronwatch.js";
import { backup } from "../lib/jobs.js";

await backup.run(async (job) => {
  const key = await uploadBackup();
  job.log("uploaded", key);
});
await cw.close();
```

```ts
// scripts/cronwatch-check.ts
import { cw } from "../lib/cronwatch.js";
import "../lib/jobs.js";   // declares every job, so one that has never run can still be missed

const result = await cw.check();
console.log(`${result.jobs.length} jobs, ${result.alerts.length} alerts`);
await cw.close();
```

```
0 3 * * *    cd /srv/app && node dist/scripts/nightly-backup.js
*/5 * * * *  cd /srv/app && node dist/scripts/cronwatch-check.js
```

Keep every `cw.job()` declaration in that one module, and import it from the job scripts and the check script alike, so the schedule a script runs under and the one the check expects can never drift apart. A job is only known to the store once it has been declared in a process that ran a check or a run, so a job that has never run and is not declared in the check process cannot be reported as missing.

## Hono, Bun, Deno and friends

`handler()` and `routes()` speak the fetch standard: they take a `Request` and return a `Response`. Mount them wherever a fetch handler goes.

```ts
import { Hono } from "hono";
import { cw } from "./cronwatch.js";

const hourly = cw.job("hourly-sync", { schedule: "@hourly" });
const routes = cw.routes({ basePath: "/cronwatch" });
const runHourly = hourly.handler(async (job) => { /* ... */ });

const app = new Hono();
app.all("/cronwatch/*", (c) => routes.handler(c.req.raw));
app.get("/jobs/hourly", (c) => runHourly(c.req.raw));
```

Make each handler once, at module level as here, rather than inside the route callback: it is the same function every time, and building it per request only adds work.

Behind a proxy that terminates TLS, `@hono/node-server` builds `c.req.raw` from the connection it sees, so its URL says `http://` and the internal host, and the dashboard refuses its own forms as cross-site. Tell the routes the public origin:

```ts
const routes = cw.routes({ basePath: "/cronwatch", origin: "https://app.example.com" });
// or, when the proxy sets (and overwrites) X-Forwarded-Proto and X-Forwarded-Host:
const routes = cw.routes({ basePath: "/cronwatch", trustProxy: true });
```

See [behind a proxy](/docs/dashboard/#behind-a-proxy).

A handler requires `Authorization: Bearer <CRON_SECRET>`. With no `CRON_SECRET` set (an empty value counts as unset) it answers 503 and runs nothing, unless the app is [in development](/docs/dashboard/#development) (`CRONWATCH_ENV`, `APP_ENV` or `NODE_ENV`, read in that order). For an endpoint that is protected some other way, say so explicitly with `secret: null`:

```ts
const runReindex = reindex.handler(async (job) => { /* ... */ }, { secret: null });
app.post("/internal/reindex", (c) => runReindex(c.req.raw));
```

Without a secret the response never includes the job's error text, only its status.

The routes want `CRONWATCH_TOKEN` in the same way. Without it, [in development](/docs/dashboard/#development), they make a token and print a sign-in link to the process's log on their first request (`[cronwatch] CRONWATCH_TOKEN is not set, so this development server made a token for the dashboard. Sign in: http://localhost:3000/cronwatch/?token=...`); open it once. Outside development they answer 503 until a token is set. See [access](/docs/dashboard/#access).

### Bun

`Bun.serve` takes a fetch handler, so the routes and any job `handler()` go straight in:

```ts
// server.ts: bun run server.ts
import { cronwatch } from "@cronwatch/sdk";
import { postgres } from "@cronwatch/sdk/postgres";

const cw = cronwatch({ store: postgres({ connectionString: process.env.DATABASE_URL }) });
const routes = cw.routes({ basePath: "/cronwatch" });

cw.start();
Bun.serve({ port: 3000, fetch: (request) => routes.handler(request) });
```

### Deno

Deno imports the packages with `npm:` specifiers and reads `CRONWATCH_TOKEN` and `CRON_SECRET` through its `process` global, so give it `--allow-env` as well as `--allow-net`. Import `pg` yourself and pass the pool: Deno does not install the store's optional peer driver on its own.

```ts
// main.ts: deno run --allow-net --allow-env main.ts
import pg from "npm:pg";
import { cronwatch } from "npm:@cronwatch/sdk";
import { postgres } from "npm:@cronwatch/sdk/postgres";

const pool = new pg.Pool({ connectionString: Deno.env.get("DATABASE_URL") });
const cw = cronwatch({ store: postgres({ pool }) });
const routes = cw.routes({ basePath: "/cronwatch" });

cw.start();
Deno.serve({ port: 3000 }, (request) => routes.handler(request));
```

### Which store where

- **Postgres** (`@cronwatch/sdk/postgres`, through `pg`) works on Node, Bun and Deno.
- **SQLite** (`@cronwatch/sdk/sqlite`, through `better-sqlite3`) is a native Node addon. It works on Node, crashes in Bun, and is not tested on Deno, so use Postgres on those two.
- **Memory**, the default, works everywhere and keeps nothing across a restart.
- **D1** is for Cloudflare Workers only; see [Cloudflare Workers](/docs/cloudflare/).

The core, the routes and every alert channel need only `fetch` and Web Crypto, so they run the same on all three. `@cronwatch/sdk/node`, below, is for Node's own request objects and is not needed on Bun or Deno.

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
