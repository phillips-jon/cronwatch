---
title: Trigger.dev
description: schedules.task runs wrapped with job.run(), attempts and retries, the Postgres store reachable from Trigger.dev, and where the check runs.
order: 3.38
group: More JavaScript platforms
---

# Trigger.dev

A `schedules.task` runs on Trigger.dev's machines, not in your app. So the store has to be a database both can reach, which means Postgres, and the check runs either as another scheduled task or in your app.

Trigger.dev keeps its own run history, with logs and traces for each attempt. CronWatch adds what that history does not: a missed schedule (a deploy that dropped the task, an environment with no worker), budgets and baselines across runs, the alerts, and one dashboard for these jobs next to the ones that run elsewhere.

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

export const digest = cw.job("daily-digest", {
  schedule: "0 6 * * *",
  timezone: "Europe/London",
  grace: "15m",
  timeout: "30m",
  failuresBeforeAlert: 3,     // the task's maxAttempts: alert when the last attempt fails
});
```

Set `DATABASE_URL` and `SLACK_WEBHOOK_URL` in the project's environment variables in the Trigger.dev dashboard, for each environment. Mark `pg` external in `trigger.config.ts` so it is installed rather than bundled:

```ts
// trigger.config.ts
import { defineConfig } from "@trigger.dev/sdk";

export default defineConfig({
  project: "<your project ref>",
  dirs: ["./src/trigger"],
  maxDuration: 300,
  build: {
    external: ["pg"],
  },
});
```

## A scheduled task

```ts
// src/trigger/daily-digest.ts
import { schedules } from "@trigger.dev/sdk";
import { digest } from "../cronwatch";

export const dailyDigest = schedules.task({
  id: "daily-digest",
  cron: { pattern: "0 6 * * *", timezone: "Europe/London" },
  maxDuration: 600,
  retry: { maxAttempts: 3 },
  run: async (payload, { ctx }) => {
    await digest.run(
      async (job) => {
        job.log("scheduled for", payload.timestamp.toISOString());
        const sent = await sendDigest();
        job.metric("emails", sent);
      },
      { trigger: `trigger.dev attempt ${ctx.attempt.number}` },
    );
  },
});
```

A `cron` given as a plain string is read in UTC; the object form takes a `timezone`. Give the job the same one. `run()` rethrows, so Trigger.dev still sees the failure and retries.

## Attempts and retries

Each attempt runs the `run` function again from the start, so each attempt is its own run in CronWatch, labelled here with its attempt number. `failuresBeforeAlert` equal to `maxAttempts` means an alert only once every attempt has failed; a retry that succeeds resets the count, and nothing is sent. Set it to 1 to hear about every failed attempt.

## Durations

`maxDuration` counts CPU time in seconds and leaves out time spent in `wait.for` and in `triggerAndWait`. CronWatch's `timeout` is wall-clock time from the start of the attempt. For a task that waits, set `timeout` to cover the waits as well as the work, or the run is marked stuck while it is only waiting. A task stopped at `maxDuration` cannot record its end; the next check after `timeout` marks it stuck.

## Work that spans tasks

When a scheduled task hands its work to another task with `trigger()` and does not wait, `run()` around the scheduled task only covers the hand-off. To watch the whole of it as one run, call `digest.start({ id: ctx.run.id })` in the scheduled task, pass the id in the payload, and in the child call `digest.resume(id)` and then `finish()`, or `fail(error)` in its `catch`. A child that never finishes leaves the run to be marked stuck after `timeout`. See [the run handle](/docs/api/#the-run-handle).

## Where the check runs

If your app already runs CronWatch with the same store, its check covers these jobs too. It learns about a job from its first run; to catch a task that has never run, declare the job in the app as well.

Otherwise, run the check as a scheduled task beside the others:

```ts
// src/trigger/cronwatch-check.ts
import { schedules } from "@trigger.dev/sdk";
import { cw } from "../cronwatch";

export const cronwatchCheck = schedules.task({
  id: "cronwatch-check",
  cron: "*/5 * * * *",
  maxDuration: 120,
  run: async () => {
    const result = await cw.check();
    return { jobs: result.jobs.length, alerts: result.alerts.length };
  },
});
```

On the free plan a schedule runs at most once an hour, which makes a missed job known up to an hour late; a check from your app avoids that.

Declarative schedules only fire in the development environment while `trigger dev` is running, and in staging and production only for tasks in the current deploy. Point development at its own database (or a different table `prefix`), so runs from a laptop do not mix with production's.

## The dashboard

Serve `cw.routes()` from your app, pointed at the same store: see [Next.js](/docs/nextjs/) or [Servers and scripts](/docs/node/).
