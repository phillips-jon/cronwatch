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
| `redact` | secret patterns | `(text) => string` applied to output and errors before they are stored or sent; `false` keeps them as logged. One that throws or returns something other than a string is reported to `onError` (as `"redact"`) and the default patterns are used for that text |
| `deliver` | `"now"` | `"check"` sends nothing from this process: alerts are queued in the store and the next check in a process that delivers now sends them, with triage. See [processes that cannot send](/docs/alerts/#processes-that-cannot-send) |
| `onError` | console | `(error, where) => void` for failures outside jobs: the store, a channel, triage |
| `now` | `Date.now` | the clock; for tests |

## cw.job(name, options)

Names are 1 to 120 characters, starting with a letter or digit, of letters, digits, `.`, `_`, `:` and `-`. Declaring the same name twice replaces the options. Options are checked when the job is declared: an unknown timezone, a zero `timeout` or `maxDuration`, a `failuresBeforeAlert` that is not a whole number of 1 or more, or a budget that is not a finite number of 0 or more all throw, rather than quietly turning a check off.

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
| `start({ trigger?, id? })` | records a running run now and returns a [run handle](#the-run-handle) to finish it later, perhaps in another process. `trigger` defaults to `"start"`. `id` (1 to 200 characters) is your own stable id, such as an Inngest run id: a start with an id already recorded returns a handle on that run instead of recording another. A store that fails is reported to `onError`, never thrown, and the run is written when it finishes |
| `resume(runId)` | a run handle on a run started elsewhere, read from the store. One that already finished, or is not in the store, gives a handle whose `finish()` records nothing and reports why to `onError`. Throws only for a run of another job |

## The job context

Passed to your function.

| | |
|---|---|
| `name`, `runId`, `startedAt` | |
| `signal` | an `AbortSignal` that fires when `timeout` elapses |
| `log(...parts)` | append a line of output (objects are JSON) |
| `metric(name, value)` | report a number |
| `metrics({ ... })` | several at once |

## The run handle

What `start()` and `resume()` return, for a run that spans several calls or processes. See [Runs that span calls](/docs/conditions/#runs-that-span-calls).

| | |
|---|---|
| `id`, `job`, `startedAt` | `startedAt` is null when a resumed run could not be read |
| `active` | false once finished, and from the start when a resumed run has already finished or was not found |
| `log(...parts)`, `metric(name, value)`, `metrics({ ... })` | as on the job context; kept in the handle until `flush()` or `finish()` |
| `flush()` | appends the lines and metrics so far to the stored run, which must still be running. Output is redacted as it is written. This reads, changes and writes the run's row, so when two processes append to one run at the same moment the last write wins and the other's lines are lost |
| `finish(outcome?)` | finishes the run and judges it like any other. `finish()` or `finish({ status: "ok" })` is a success; `finish({ error })` a failure, recorded like an error `run()` caught; `finish("text")` or `finish({ result })` treats the value like `run()`'s return (a string is the output when nothing was logged and is checked by `expect`; a `Response` of 400 or above fails). Lines and metrics from the handle are added to those already stored, then `expect`, redaction and the 16 KB cap apply. Resolves to the recorded run, or null when nothing was recorded |
| `fail(error)` | `finish({ error })` |

A second `finish()` on a handle, or on a run another process has finished, records nothing: it resolves to null and is reported to `onError`, never thrown. A run that is never finished is marked stuck by the first check after the job's `timeout`; one finished after that follows the same rule as a late `run()`: a late failure is not counted again, and a late success closes stuck and recovers.

## The client

| Method | |
|---|---|
| `run(name, options?, fn)` | run without keeping a handle; declares the job on first use |
| `check()` | find missed and stuck runs, send alerts, retry alerts no channel accepted, prune. Returns `{ checkedAt, jobs, alerts, pruned }`. Concurrent calls share one check. A job that cannot be evaluated is reported to `onError` and listed as `failing`; the rest are checked as usual |
| `start(every = "1m")`, `stop()` | check on an interval. With `deliver: "check"`, `start()` warns once on the console that these checks send nothing and another process must |
| `routes({ token?, basePath? })` | the [dashboard and API](/docs/dashboard/) handlers. `token` defaults to `CRONWATCH_TOKEN` (empty counts as unset); with none, while `NODE_ENV` is `development` or `test` the routes make a random token and print a sign-in link to the server log on their first request, and otherwise answer 503. `token: null` opts out to serve them open. Cross-site writes are refused, `?token=` is read only on a page `GET`, and a silence `for` that is not a duration or a number of milliseconds is a 400 |
| `jobs()` | every job's summary, without alerting |
| `jobsWithRuns(limit = 20)` | every job's summary with its newest `limit` runs, read together: `{ job, runs }[]` |
| `jobSummary(name)`, `getRun(id)` | |
| `runs(name, limit = 50)` | newest first; `limit` is truncated to a whole number from 1 to 500 |
| `silence(name, duration)`, `unsilence(name)` | |
| `forget(name)` | remove a job and its runs from the store |
| `definedJobs()` | the definitions declared in this process |
| `close()` | stop the interval and close the store |
| `resumeRun(name, runId)` | `job(name).resume(runId)` for a job declared in this process; rejects for one that is not |

## Exports

`@cronwatch/sdk`: `cronwatch`, `CronWatch`, `memory`, `custom`, `consoleChannel`, `createRoutes`, `parseDuration`, `formatDuration`, `parseSchedule`, `nextFire` (the next time a parsed schedule fires after a given time), `composeAlert`, and every type they use, including `Alert`, `AlertDraft`, `AlertDetails` and `ParsedSchedule`.

`@cronwatch/sdk/sqlite`, `/postgres`, `/slack`, `/discord`, `/webhook`, `/anthropic`: one adapter each. `/sqlite` needs `better-sqlite3` and `/postgres` needs `pg`, both optional peer dependencies. `/anthropic` needs `@anthropic-ai/sdk`, which you install yourself. `/slack`, `/discord` and `/webhook` need nothing.
