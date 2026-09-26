---
title: What it catches
description: The conditions CronWatch reports, how each is decided, baselines, expect rules, budgets and silence.
order: 5
---

# What it catches

Every condition is opened once, sends one alert, and stays open until it clears. Once it has cleared, the next successful run that leaves nothing open sends one **recovered** message naming what was recovered from. A job failing all night pages you once.

## missed

The schedule said a run was due and none started within the grace period. Decided by `cw.check()`; see [Schedules](/docs/schedules/). Closes when a run starts; the recovered message follows the next successful run.

## failed

Any of:

- the function threw (the error's name, message and the first stack frames are recorded),
- the handler returned a `Response` with status 400 or above,
- the job has an `expect` rule and the output did not satisfy it.

Alerts on the first failure by default. Set `failuresBeforeAlert: 3` to wait for the third consecutive one, for jobs that flake and self-heal. It must be a whole number, 1 or more; `cw.job()` throws otherwise. Consecutive failures are counted either way and shown on the dashboard.

## stuck

A run started and never reported finishing within `timeout`. Marked as `timeout` by the next check, counted as a failure. Usually a killed process: a serverless limit, a deploy, an OOM. Closes when the next run starts; the recovered message follows the next successful run.

## slow

A successful run took longer than it should. The threshold is:

- `maxDuration`, if the job sets one, or
- twice the p95 of the job's last twenty successful runs, once there are at least five to compare against, with a floor of ten seconds so a job that usually takes 200ms is not called slow at 500ms.

Closes when a successful run is back under the threshold.

## over_budget

A metric reported with `job.metric(name, value)` went above its limit. The limit is:

- `budget[name]`, if the job sets one (a finite number, 0 or more; `budget: { errors: 0 }` alerts on any error), or
- three times the median of that metric over the last twenty successful runs, once there are at least five.

All breaching metrics are listed in one alert. Closes when a run's metrics are all within limits again.

## recovered

A run succeeded and no condition remains open. The message names everything that alerted and has cleared since the last recovery, for example "after: missed, failed". A condition that closed while another stayed open waits for this message, so every alert is answered by a recovery once the job is healthy again.

## expect rules

`expect` turns a quiet success into a failure when the job produced no evidence of doing its work. The output is whatever the job logged with `job.log()`, or the string the function returned if it logged nothing.

```ts
cw.job("export", { expect: "wrote" });                       // output must contain the string
cw.job("export", { expect: /wrote \d+ files/ });             // or match the pattern
cw.job("export", { expect: (out) => out.split("\n").length > 3 });   // or pass a function
```

## Baselines

Baselines use the last twenty successful runs, reading past any failures in between, and need at least five. Before that, only explicit limits apply. A job's history is its own: a slow job is compared to itself.

## Silence

`cw.silence(name, "2h")`, the dashboard button, or the MCP tool. While silenced, nothing new is recorded as an incident and no alerts are sent; conditions that clear during the silence do clear. When the silence ends, the next problem alerts normally.

## Output and metrics

Output, whether logged or returned, is capped at 16 KB per run, keeping the tail. Metrics are numbers keyed by name; report as many as you like. Both are stored with the run, shown on the dashboard and in alerts, and handed to the MCP server and to triage.
