---
title: Firebase
description: Scheduled functions from firebase-functions/v2/scheduler wrapped with job.run(), a scheduled check, and the dashboard as an HTTP function.
order: 3.36
group: More JavaScript platforms
---

# Firebase

A 2nd gen scheduled function is a Cloud Scheduler job that calls a function on a schedule. Each call is a short-lived instance with no disk, so the store is Postgres (Cloud SQL, Neon, Supabase, anything the function can reach), and the check is one more scheduled function.

## The client

```ts
// functions/src/cronwatch.ts
import { cronwatch } from "@cronwatch/sdk";
import { postgres } from "@cronwatch/sdk/postgres";
import { slack } from "@cronwatch/sdk/slack";

export const cw = cronwatch({
  store: postgres({ connectionString: process.env.DATABASE_URL }),
  alerts: [slack({ webhookUrl: process.env.SLACK_WEBHOOK_URL! })],
  defaults: { timezone: "Europe/London" },   // the same zone the schedules below use
});

export const digest = cw.job("daily-digest", { schedule: "0 6 * * *", grace: "10m", timeout: "10m" });
```

Keep the connection string and webhook URL in Secret Manager (`firebase functions:secrets:set DATABASE_URL`) and bind them to each function that uses the client; a bound secret is read from `process.env`.

## A scheduled function

```ts
// functions/src/index.ts
import { onSchedule } from "firebase-functions/v2/scheduler";
import { cw, digest } from "./cronwatch.js";

const secrets = ["DATABASE_URL", "SLACK_WEBHOOK_URL"];

export const dailyDigest = onSchedule(
  { schedule: "0 6 * * *", timeZone: "Europe/London", timeoutSeconds: 540, secrets },
  async () => {
    await digest.run(async (job) => {
      const sent = await sendDigest();
      job.metric("emails", sent);
    });
  },
);
```

`run()` rethrows, so a failed run fails the invocation too, and Cloud Scheduler records the attempt as failed.

Without `timeZone`, a 2nd gen schedule runs in UTC; set it and the job's `timezone` to the same zone. Cloud Scheduler also takes its own English syntax (`every 5 minutes`, `every day 06:00`). CronWatch does not, so for a job write the equivalent cron expression, or an interval such as `every 5m`.

## The check

```ts
export const cronwatchCheck = onSchedule(
  { schedule: "every 5 minutes", timeoutSeconds: 120, secrets },
  async () => {
    await cw.check();
  },
);
```

This function imports the module that declares every job, so a job that has never run is known to the check. Cloud Scheduler bills per job past a small free allowance, and the check is one more.

## Retries and timeouts

Cloud Scheduler does not retry a failed attempt unless you set `retryCount`. Each retry is a fresh invocation and a separate run in CronWatch, so with `retryCount: 2` set `failuresBeforeAlert: 3` on the job to hear about it only when the last attempt fails too. A retry that succeeds resets the count.

When an invocation passes its `timeoutSeconds`, it is stopped before it can record its end. The run stays `running` until a check passes the job's `timeout` and marks it stuck, so set `timeout` a little above `timeoutSeconds`. Cloud Scheduler waits at most 30 minutes for a scheduled call, so work that needs longer should be handed to a task queue or a Cloud Run job, with the run wrapped there.

## Functions that should not send alerts

A secret has to be bound to each function that reads it. To keep the Slack webhook on the check function only, give the job functions a client created with `deliver: "check"` and the same store, declaring the same jobs: it records runs and queues alerts, and the next scheduled check, whose client sends as usual, delivers them. A failure then reaches Slack up to five minutes later. See [processes that cannot send](/docs/alerts/#processes-that-cannot-send).

## The dashboard

`onRequest` hands over Express-style request and response objects, and `toNodeHandler` from `@cronwatch/sdk/node` turns the routes into a function that takes them. Firebase reads the request body before the function runs and keeps it as `req.rawBody`, which the adapter passes on.

```ts
import { onRequest } from "firebase-functions/v2/https";
import { toNodeHandler } from "@cronwatch/sdk/node";

const routes = cw.routes({ basePath: "" });

export const cronwatchDashboard = onRequest(
  { secrets: [...secrets, "CRONWATCH_TOKEN"] },
  toNodeHandler(routes.handler, { trustProxy: true }),
);
```

With `basePath: ""` the dashboard sits at the root of the function's own URL, which `firebase deploy` prints. Open it once with `?token=<CRONWATCH_TOKEN>`. To serve it under your site instead, add a Hosting rewrite from `/cronwatch` and `/cronwatch/**` to the function and set `basePath` to `/cronwatch`.

Google's front end terminates TLS and tells the function with `X-Forwarded-Proto`, which `trustProxy: true` lets it follow; without it the function sees plain `http` and refuses the dashboard's forms as cross-site. Behind the Hosting rewrite, also pass the site's origin to the routes (`cw.routes({ basePath: "/cronwatch", origin: "https://example.com" })`), since the request reaches the function under the function's own host.
