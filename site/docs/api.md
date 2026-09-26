---
title: API reference
description: Every option on cronwatch(), cw.job(), the job handle, the job context and the client.
order: 12
---

# API reference

## cronwatch(options)

| Option | Default | |
|---|---|---|
| `store` | in memory | a [store](/docs/stores/) |
| `alerts` | console | an array of [channels](/docs/alerts/) |
| `triage` | | a [triage function](/docs/triage/) |
| `cronSecret` | `process.env.CRON_SECRET` | what `handler()` requires as a bearer; `null` disables the check |
| `retention` | `"30d"` | how long finished runs are kept |
| `defaults` | | `grace`, `timeout`, `timezone`, `failuresBeforeAlert` applied to every job |
| `onError` | console | `(error, where) => void` for failures outside jobs |
| `now` | `Date.now` | the clock; for tests |

## cw.job(name, options)

Names are 1 to 120 characters of letters, digits, `.`, `_`, `:` and `-`. Declaring the same name twice replaces the options.

| Option | Default | |
|---|---|---|
| `schedule` | none | cron expression, nickname, or `every <duration>` |
| `timezone` | process timezone | IANA name the cron is read in |
| `grace` | `"10m"` | how late a start may be before the run is missed |
| `timeout` | `"1h"` | a run still going after this is stuck |
| `maxDuration` | baseline | a successful run longer than this is slow |
| `budget` | baseline | `{ metric: ceiling }` |
| `expect` | | string, RegExp or `(output) => boolean` the output must satisfy |
| `failuresBeforeAlert` | `1` | alert on the Nth consecutive failure |
| `description`, `tags` | | shown on the dashboard |

Returns a handle:

| Method | |
|---|---|
| `run(fn, { trigger? })` | runs `fn(job)`, records the run, returns its result, rethrows its error |
| `handler(fn, { secret? })` | a `(request) => Promise<Response>` that checks the bearer secret, runs `fn(job, request)` and answers with JSON, or with the `Response` `fn` returned |

## The job context

Passed to your function.

| | |
|---|---|
| `name`, `runId`, `startedAt` | |
| `signal` | an `AbortSignal` that fires when `timeout` elapses |
| `log(...parts)` | append a line of output (objects are JSON) |
| `metric(name, value)` | report a number |
| `metrics({ ... })` | several at once |

## The client

| Method | |
|---|---|
| `run(name, options?, fn)` | run without keeping a handle; declares the job on first use |
| `check()` | find missed and stuck runs, send alerts, prune. Returns `{ checkedAt, jobs, alerts, pruned }`. Concurrent calls share one check. |
| `start(every = "1m")`, `stop()` | check on an interval |
| `routes(options?)` | the [dashboard and API](/docs/dashboard/) handlers |
| `jobs()` | every job's summary, without alerting |
| `jobSummary(name)`, `runs(name, limit?)`, `getRun(id)` | |
| `silence(name, duration)`, `unsilence(name)` | |
| `forget(name)` | remove a job and its runs from the store |
| `definedJobs()` | the definitions declared in this process |
| `close()` | stop the interval and close the store |

## Exports

`@cronwatch/sdk`: `cronwatch`, `CronWatch`, `memory`, `custom`, `consoleChannel`, `createRoutes`, `parseDuration`, `parseSchedule`, `composeAlert`, and every type.

`@cronwatch/sdk/sqlite`, `/postgres`, `/slack`, `/discord`, `/webhook`, `/anthropic`: one adapter each, with the driver as an optional peer dependency.
