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
| `cronSecret` | `process.env.CRON_SECRET` | what `handler()` requires as a bearer. Empty counts as unset, and with none set handlers answer 503 outside development. `null` lets handlers run without one |
| `retention` | `"30d"` | how long finished runs are kept |
| `defaults` | | `grace`, `timeout`, `timezone`, `failuresBeforeAlert` applied to every job |
| `onError` | console | `(error, where) => void` for failures outside jobs: the store, a channel, triage |
| `now` | `Date.now` | the clock; for tests |

## cw.job(name, options)

Names are 1 to 120 characters of letters, digits, `.`, `_`, `:` and `-`. Declaring the same name twice replaces the options. Options are checked when the job is declared: an unknown timezone, a zero `timeout` or `maxDuration`, a `failuresBeforeAlert` that is not a whole number of 1 or more, or a budget that is not a finite number of 0 or more all throw, rather than quietly turning a check off.

| Option | Default | |
|---|---|---|
| `schedule` | none | cron expression, nickname, or `every <duration>` |
| `timezone` | process timezone | IANA name the cron is read in |
| `grace` | `"10m"` | how late a start may be before the run is missed |
| `timeout` | `"1h"` | a run still going after this is stuck |
| `maxDuration` | baseline | a successful run longer than this is slow |
| `budget` | baseline | `{ metric: ceiling }`, each ceiling a finite number, 0 or more |
| `expect` | | string, RegExp or `(output) => boolean` the output must satisfy |
| `failuresBeforeAlert` | `1` | alert on the Nth consecutive failure; a whole number, 1 or more |
| `description`, `tags` | | shown on the dashboard |

Returns a handle:

| Method | |
|---|---|
| `run(fn, { trigger? })` | runs `fn(job)`, records the run, returns its result, rethrows its error |
| `handler(fn, { secret? })` | a `(request) => Promise<Response>` that checks the bearer secret, runs `fn(job, request)` and answers with JSON, or with the `Response` `fn` returned. `secret` defaults to the client's `cronSecret`; `null` accepts anyone, and then the JSON leaves out the error text |

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
| `check()` | find missed and stuck runs, send alerts, retry alerts no channel accepted, prune. Returns `{ checkedAt, jobs, alerts, pruned }`. Concurrent calls share one check. |
| `start(every = "1m")`, `stop()` | check on an interval |
| `routes({ token?, basePath? })` | the [dashboard and API](/docs/dashboard/) handlers. `token` defaults to `CRONWATCH_TOKEN` (empty counts as unset); with none, the routes serve only when `NODE_ENV` is `development` or `test`, and `token: null` opts out to serve them open. Cross-site writes are refused, `?token=` is read only on a page `GET`, and a silence `for` that is not a duration or a number of milliseconds is a 400 |
| `jobs()` | every job's summary, without alerting |
| `jobsWithRuns(limit = 20)` | every job's summary with its newest `limit` runs, read together: `{ job, runs }[]` |
| `jobSummary(name)`, `getRun(id)` | |
| `runs(name, limit = 50)` | newest first; `limit` is truncated to a whole number from 1 to 500 |
| `silence(name, duration)`, `unsilence(name)` | |
| `forget(name)` | remove a job and its runs from the store |
| `definedJobs()` | the definitions declared in this process |
| `close()` | stop the interval and close the store |

## Exports

`@cronwatch/sdk`: `cronwatch`, `CronWatch`, `memory`, `custom`, `consoleChannel`, `createRoutes`, `parseDuration`, `formatDuration`, `parseSchedule`, `nextFire` (the next time a parsed schedule fires after a given time), `composeAlert`, and every type they use, including `Alert`, `AlertDraft`, `AlertDetails` and `ParsedSchedule`.

`@cronwatch/sdk/sqlite`, `/postgres`, `/slack`, `/discord`, `/webhook`, `/anthropic`: one adapter each, with the driver as an optional peer dependency.
