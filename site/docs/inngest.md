---
title: Inngest
description: Cron-triggered Inngest functions, how steps and retries map to runs, and the check as another cron function.
order: 3.39
group: More platforms
---

# Inngest

Inngest schedules the function and calls it over HTTP, but the code runs in your app, behind the endpoint that `serve()` mounts. So the client, the store and the dashboard are your app's own, set up as on the page for your framework ([Next.js](/docs/nextjs/), [Servers and scripts](/docs/node/)). What needs care is how Inngest runs a function.

## How a function runs

One function run can take several calls to your endpoint. Every call runs the handler from the top, and a step that already finished returns its saved result instead of running again. A failed step is retried on its own, up to four times by default, without rerunning the steps before it.

So wrapping the whole handler in `run()` would record a run for every call, not every function run. Wrap the work inside a step instead: the step's body runs once per attempt, so each attempt is one run.

## A cron function

```ts
// src/cronwatch.ts, next to the client
export const digest = cw.job("daily-digest", {
  schedule: "0 6 * * *",
  timezone: "Europe/Paris",
  grace: "15m",
  timeout: "10m",
  failuresBeforeAlert: 5,     // Inngest's default: the first attempt and four retries
});
```

```ts
// src/inngest/daily-digest.ts
import { inngest } from "./client";
import { digest } from "../cronwatch";

export const dailyDigest = inngest.createFunction(
  { id: "daily-digest", triggers: { cron: "TZ=Europe/Paris 0 6 * * *" } },
  async ({ step, attempt }) => {
    const sent = await step.run("send-digest", () =>
      digest.run(
        async (job) => {
          const count = await sendDigest();
          job.metric("emails", count);
          return count;
        },
        { trigger: `inngest attempt ${attempt}` },
      ),
    );
    return { sent };
  },
);
```

Put the zone in both places: a `TZ=` prefix on Inngest's expression and `timezone` on the job, so the two read the schedule the same way. `attempt` counts from 0.

`run()` rethrows, so Inngest sees the failure and retries the step. With `failuresBeforeAlert` equal to the number of attempts, you hear once every attempt has failed; a retry that succeeds resets the count and sends nothing. If the function sets `retries`, match it: `retries: 2` is three attempts.

## Several steps

A run is one call to `run()`, so it cannot span steps that Inngest may run in separate requests, perhaps hours apart after a `step.sleep`. Declare a job for each step that matters. Put the schedule on the first, so a function that never starts is reported missed, and leave it off the rest, which are still watched for failures, duration and budgets.

```ts
const loadStep = cw.job("digest:load-recipients", { schedule: "0 6 * * *", timezone: "Europe/Paris", failuresBeforeAlert: 5 });
const sendStep = cw.job("digest:send", { failuresBeforeAlert: 5 });

export const dailyDigestSteps = inngest.createFunction(
  { id: "daily-digest-steps", triggers: { cron: "TZ=Europe/Paris 0 6 * * *" } },
  async ({ step }) => {
    const recipients = await step.run("load-recipients", () => loadStep.run(() => loadRecipients()));
    const sent = await step.run("send", () => sendStep.run(() => sendDigestTo(recipients)));
    return { sent };
  },
);
```

## The check

In a long-running server, `cw.start()` does it. On serverless, a cron on your platform can call `/cronwatch/api/check`, or Inngest can run it:

```ts
// src/inngest/cronwatch-check.ts
export const cronwatchCheck = inngest.createFunction(
  { id: "cronwatch-check", triggers: { cron: "*/5 * * * *" }, retries: 0 },
  async () => {
    const result = await cw.check();
    return { jobs: result.jobs.length, alerts: result.alerts.length };
  },
);
```

It has no steps, so it runs once per fire. Retries are off because the next fire, five minutes on, does the same work. Add it to the `functions` passed to `serve()` with the others.

## Limits that matter

Each call is an ordinary request to your app, so your host's time limit applies to one step, not the whole function. A step cut off at that limit is marked stuck by the first check after the job's `timeout`; set `timeout` a little above the host's limit. The free plan pauses a cron function after 20 consecutive failures; CronWatch sees the missed schedule that follows and alerts once.
