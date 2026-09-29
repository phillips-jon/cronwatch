---
title: Inngest
description: Cron-triggered Inngest functions as one run each, started in the first step and finished in the last, with failures from onFailure, and the check as another cron function.
order: 3.39
group: More JavaScript platforms
---

# Inngest

Inngest schedules the function and calls it over HTTP, but the code runs in your app, behind the endpoint that `serve()` mounts. So the client, the store and the dashboard are your app's own, set up as on the page for your framework ([Next.js](/docs/nextjs/), [Servers and scripts](/docs/node/)). What needs care is how Inngest runs a function.

## How a function runs

One function run can take several calls to your endpoint. Every call runs the handler from the top, and a step that already finished returns its saved result instead of running again. A failed step is retried on its own, up to four times by default, without rerunning the steps before it. Between steps a function can sleep for hours.

So wrapping the handler in `run()` would record a run for every call, not every function run. Use `start()` and `finish()` instead: start a CronWatch run in the first step, finish it in the last, and record a failure from `onFailure`. Each gets the same id, Inngest's own run id, so one Inngest function run is one CronWatch run, however many calls and retries it takes.

## A cron function

```ts
// src/cronwatch.ts, next to the client
export const digest = cw.job("daily-digest", {
  schedule: "0 6 * * *",
  timezone: "Europe/Paris",
  grace: "15m",
  timeout: "2h",      // the whole function run: every step, retry and sleep
});
```

```ts
// src/inngest/daily-digest.ts
import { inngest } from "./client";
import { digest } from "../cronwatch";

export const dailyDigest = inngest.createFunction(
  {
    id: "daily-digest",
    triggers: { cron: "TZ=Europe/Paris 0 6 * * *" },
    onFailure: async ({ event, error }) => {
      const run = await digest.resume(event.data.run_id);
      await run.fail(error);
    },
  },
  async ({ step, runId }) => {
    await step.run("cronwatch-start", async () => {
      await digest.start({ id: runId, trigger: "inngest" });
    });

    const recipients = await step.run("load-recipients", () => loadRecipients());
    const sent = await step.run("send", () => sendDigestTo(recipients));

    await step.run("cronwatch-finish", async () => {
      const run = await digest.resume(runId);
      run.log(`sent ${sent} emails to ${recipients.length} recipients`);
      run.metric("emails", sent);
      await run.finish();
    });
    return { sent };
  },
);
```

Put the zone in both places: a `TZ=` prefix on Inngest's expression and `timezone` on the job, so the two read the schedule the same way.

The start is its own step so it runs once: later calls get its saved result and do not touch the store. If that step is retried, a second `start()` with the same id records nothing new and hands back the run already started. The finish step reads the run back with `resume()`, adds what it logged and its metrics, and judges it: `expect`, duration from the start, budgets. A step in the middle can add lines too, with `resume()`, `log()` and `await run.flush()`.

A step that throws is retried by Inngest while the CronWatch run stays running, so a retry that succeeds sends nothing. Once a step has used its last retry, the function fails and `onFailure` runs with Inngest's run id in `event.data.run_id` and the final error; `fail()` records it as the run's failure and alerts. So `failuresBeforeAlert` counts failed function runs, not attempts, and the default of 1 alerts on the first function run that fails. `resume()`, `finish()` and `fail()` never throw for the store: what goes wrong is reported to `onError`, so a store outage cannot fail the function.

## Runs that never finish

A function run that is cancelled, or whose last step never reports back, leaves its CronWatch run running. The first check after the job's `timeout` marks it stuck and alerts. Set `timeout` above the longest the whole function takes, sleeps and retry backoff included, or a run that is only waiting is called stuck. If it does finish after that, a late failure is not counted twice and a late success recovers.

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

Each call is an ordinary request to your app, so your host's time limit applies to one step, not the whole function. A step cut off at that limit is retried by Inngest like one that threw. The free plan pauses a cron function after 20 consecutive failures; CronWatch sees the missed schedule that follows and alerts once.
