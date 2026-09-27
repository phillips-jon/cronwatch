---
title: Netlify
description: Scheduled functions wrapped with job.run(), a scheduled function for the check, and the dashboard as a function on a path.
order: 3.35
group: More platforms
---

# Netlify

A Netlify scheduled function runs on a cron schedule, in UTC, for at most 30 seconds. It cannot be called by URL in production, so there is no request to authenticate: wrap the body in `run()` rather than using `handler()`. The check is one more scheduled function, and the dashboard is an ordinary function with a path.

## The client

Functions have no persistent disk, so use Postgres.

```ts
// lib/cronwatch.ts
import { cronwatch } from "@cronwatch/sdk";
import { postgres } from "@cronwatch/sdk/postgres";
import { slack } from "@cronwatch/sdk/slack";

export const cw = cronwatch({
  store: postgres({ connectionString: process.env.DATABASE_URL }),
  alerts: [slack({ webhookUrl: process.env.SLACK_WEBHOOK_URL! })],
  defaults: { timezone: "UTC" },      // Netlify runs schedules in UTC
});

export const digest = cw.job("daily-digest", { schedule: "0 6 * * *", grace: "10m", timeout: "2m" });
```

Set `DATABASE_URL`, `SLACK_WEBHOOK_URL` and `CRONWATCH_TOKEN` in the site's environment variables with the Functions scope. Variables written in `netlify.toml` are not passed to functions.

## A scheduled function

```ts
// netlify/functions/daily-digest.ts
import type { Config } from "@netlify/functions";
import { digest } from "../../lib/cronwatch";

export default async () => {
  await digest.run(async (job) => {
    const sent = await sendDigest();
    job.metric("emails", sent);
  });
};

export const config: Config = {
  schedule: "0 6 * * *",
};
```

The schedule can live in `netlify.toml` instead:

```toml
[functions."daily-digest"]
schedule = "0 6 * * *"
```

Netlify accepts five-field cron and the nicknames `@hourly`, `@daily`, `@weekly`, `@monthly` and `@yearly`, and so does a job's `schedule`, so copy the same string into both.

## The check

```ts
// netlify/functions/cronwatch-check.ts
import type { Config } from "@netlify/functions";
import { cw } from "../../lib/cronwatch";   // the module declares every job, so one that never ran is known

export default async () => {
  const result = await cw.check();
  console.log(`${result.jobs.length} jobs, ${result.alerts.length} alerts`);
};

export const config: Config = {
  schedule: "*/5 * * * *",
};
```

The check has the same 30 seconds. Sending alerts and retrying queued ones usually takes a second or two, but [triage](/docs/triage/) waits on a model for each alert, and one check spends up to 20 seconds retrying alerts no channel accepted. Leave triage off in the client this function uses, or run the check from somewhere without the limit (another host's cron calling `/cronwatch/api/check` with `CRON_SECRET` as the bearer).

## The dashboard

Netlify functions take a fetch `Request` and return a `Response`, so the routes need no adapter. A path pattern with `/*` does not match the bare path, so list both.

```ts
// netlify/functions/cronwatch.ts
import type { Config } from "@netlify/functions";
import { cw } from "../../lib/cronwatch";

const routes = cw.routes({ basePath: "/cronwatch" });

export default (request: Request) => routes.handler(request);

export const config: Config = {
  path: ["/cronwatch", "/cronwatch/*"],
};
```

Open `/cronwatch?token=<CRONWATCH_TOKEN>` once.

## Limits that matter

A scheduled function stopped at 30 seconds cannot record its end. The run stays `running` until a check passes the job's `timeout`, then it is marked stuck, so keep `timeout` short: a minute or two. Work that needs longer belongs in a background function (up to 15 minutes), which a scheduled function cannot be. Have the scheduled function call the background one's URL with `Authorization: Bearer <CRON_SECRET>`, and wrap the work in the background function with `handler()`, which refuses a call without the secret. The job keeps its schedule, so a background run that never starts is still reported missed; give it a `timeout` a little over 15 minutes.

Scheduled functions run only on the published production deploy. Deploy previews and branch deploys do not run them on schedule (the Netlify UI can run one by hand), so the check runs from production alone.
