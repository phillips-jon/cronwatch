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
const app = new Hono();
const routes = cw.routes({ basePath: "/cronwatch" });
app.all("/cronwatch/*", (c) => routes.handler(c.req.raw));
app.get("/jobs/hourly", (c) => hourly.handler(async () => { /* ... */ })(c.req.raw));
```

A handler requires `Authorization: Bearer <CRON_SECRET>`. With no `CRON_SECRET` set (an empty value counts as unset) it answers 503 and runs nothing, unless `NODE_ENV` is `development` or `test`. For an endpoint that is protected some other way, say so explicitly with `secret: null`:

```ts
app.post("/internal/reindex", (c) => reindex.handler(async () => { /* ... */ }, { secret: null })(c.req.raw));
```

Without a secret the response never includes the job's error text, only its status.

The stores use Node drivers (`better-sqlite3`, `pg`), so the process needs Node compatibility; Bun runs both.
