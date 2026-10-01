---
title: TypeScript API reference
description: Every option on cronwatch(), cw.job(), the job handle, the job context and the client.
order: 12
group: Reference
---

# TypeScript API reference

## cronwatch(options)

| Option | Default | |
|---|---|---|
| `store` | in memory | a [store](/docs/stores/) |
| `sources` | `[]` | where runs this process does not wrap come from, such as [`pgCron(pool)`](/docs/supabase/). Each source is synced at the start of every `check()`; one that throws is reported to `onError` and the check carries on |
| `alerts` | console | an array of [channels](/docs/alerts/) |
| `triage` | | a [triage function](/docs/triage/) |
| `cronSecret` | `process.env.CRON_SECRET` | what `handler()` requires as a bearer. Empty or only whitespace counts as unset (given here or in the variable), and a value that is neither a string nor `null` throws; with none set handlers answer 503 outside development. `null` lets handlers run without one |
| `retention` | `"30d"` | how long finished runs are kept |
| `defaults` | | `grace`, `timeout`, `timezone`, `failuresBeforeAlert` applied to every job |
| `redact` | secret patterns | `(text) => string` applied to output and errors before they are stored or sent; `false` keeps them as logged. One that throws or returns something other than a string is reported to `onError` (as `"redact"`) and the default patterns are used for that text |
| `deliver` | `"now"` | `"check"` sends nothing from this process: alerts are queued in the store and the next check in a process that delivers now sends them, with triage. See [processes that cannot send](/docs/alerts/#processes-that-cannot-send) |
| `onError` | console | `(error, where) => void` for failures outside jobs: the store, a channel, triage |
| `now` | `Date.now` | the clock; for tests |

## cw.job(name, options)

Names are 1 to 120 characters, starting with a letter or digit, of letters, digits, `.`, `_`, `:` and `-`. Declaring the same name twice replaces the options. Options are checked when the job is declared: an unknown timezone, a schedule that does not parse or an interval under one second, a `grace`, `timeout` or `maxDuration` that is not a duration, a zero `timeout` or `maxDuration`, a `failuresBeforeAlert` that is not a whole number of 1 or more, or a budget that is not a finite number of 0 or more all throw, rather than quietly turning a check off. A duration string longer than 64 characters throws too, wherever one is read (these options, the interval in `every`, `retention`, `startChecking()` and `silence()`); no real duration comes near it.

| Option | Default | |
|---|---|---|
| `schedule` | none | cron expression, nickname, or `every <duration>` |
| `timezone` | process timezone | IANA name the cron is read in |
| `grace` | `"10m"` | how late a start may be before the run is missed |
| `timeout` | `"1h"` | a run still going after this is stuck: marked `timeout`, counted as a failure, and alerted as stuck. The job's signal aborts then |
| `maxDuration` | baseline | a run that succeeded but took longer than this is slow: it stays `ok` and is alerted as slow. Without it, slow is more than twice the p95 of recent successful runs (and over 10 seconds) |
| `budget` | baseline | `{ metric: ceiling }`, each ceiling a finite number, 0 or more |
| `expect` | | string, RegExp or `(output) => boolean` the output must satisfy. A RegExp, like a function, runs without a time limit: see [expect rules](/docs/conditions/#expect-rules) |
| `failuresBeforeAlert` | `1` | alert on the Nth consecutive failure; a whole number, 1 or more |
| `description`, `tags` | | shown on the dashboard |

`timeout` and `maxDuration` both measure a run's length, and are easy to mix up. `timeout` is for a run that has not finished: once a running run is older than it, the next check gives up on it (the run becomes `timeout`, a failure) and the job is stuck. `maxDuration` is for a run that finished: one that succeeded but took longer is slow, and stays a success. So `timeout` should be well above `maxDuration`: `{ maxDuration: "10m", timeout: "1h" }` hears about a run that crept past ten minutes, and gives up on one still going after an hour.

Returns a handle:

| Method | |
|---|---|
| `run(fn, { trigger? })` | runs `fn(job)`, records the run, returns its result, rethrows its error |
| `handler(fn, { secret? })` | a `(request) => Promise<Response>` that checks the bearer secret, runs `fn(job, request)` and answers with JSON, or with the `Response` `fn` returned. `secret` defaults to the client's `cronSecret` (also when empty or only whitespace; neither a string nor `null`, it throws); `null` accepts anyone, and then the JSON leaves out the error text |
| `start({ trigger?, id? })` | records a running run now and returns a [run handle](#the-run-handle) to finish it later, perhaps in another process. `trigger` defaults to `"start"`. `id` (1 to 200 characters) is your own stable id, such as an Inngest run id: a start with an id already recorded returns a handle on that run instead of recording another. A store that fails is reported to `onError`, never thrown, and the run is written when it finishes |
| `resume(runId)` | a run handle on a run started elsewhere, read from the store. One that already finished, or is not in the store, gives a handle whose `finish()` records nothing and reports why to `onError`. Throws only for a run of another job, or for an id that is empty, longer than 200 characters or starts with `pgcron:` (the same rules as `start({ id })`) |

## The job context

Passed to your function.

| | |
|---|---|
| `name`, `runId`, `startedAt` | |
| `signal` | an `AbortSignal` that fires when `timeout` elapses |
| `log(...parts)` | append a line of output (objects are JSON) |
| `metric(name, value)` | report a number; throws for a value that is not a finite number (`NaN`, `Infinity`, a string) |
| `metrics({ ... })` | several at once |

## The run handle

What `start()` and `resume()` return, for a run that spans several calls or processes. See [Runs that span calls](/docs/conditions/#runs-that-span-calls).

| | |
|---|---|
| `id`, `job`, `startedAt` | `startedAt` is null when a resumed run could not be read |
| `active` | false once finished, and from the start when a resumed run has already finished or was not found |
| `log(...parts)`, `metric(name, value)`, `metrics({ ... })` | as on the job context; kept in the handle until `flush()` or `finish()` |
| `flush()` | appends the lines and metrics so far to the stored run, which must still be running. Output is redacted as it is written. This reads, changes and writes the run's row, so when two processes append to one run at the same moment the last write wins and the other's lines are lost |
| `finish(outcome?)` | finishes the run and judges it like any other; see [below](#finish) |
| `fail(error)` | `finish({ error })` |

### finish()

- `finish()` or `finish({ status: "ok" })` is a success.
- `finish({ error })` is a failure, recorded like an error `run()` caught.
- `finish("text")` or `finish({ result })` treats the value like `run()`'s return: a string is the output when nothing was logged and is checked by `expect`, and a `Response` of 400 or above fails.
- Lines and metrics from the handle are added to those already stored, then `expect`, redaction and the 16 KB cap apply.
- It resolves to the recorded run, or null when nothing was recorded.

A second `finish()` on a handle, or on a run another process has finished, records nothing: it resolves to null and is reported to `onError`, never thrown. When two processes finish one run at the same moment, only one records and judges it. If the store fails during `finish()`, the handle stays active so `finish()` can be called again. An id belongs to one job: `start()` or `resume()` with an id another job's run already has throws, and ids starting with `pgcron:` are reserved for the pg_cron source. A run that is never finished is marked stuck by the first check after the job's `timeout`; one finished after that follows the same rule as a late `run()`: a late failure is not counted again, and a late success closes stuck and recovers.

## The client

| Method | |
|---|---|
| `run(name, options?, fn)` | run without keeping a handle; declares the job on first use |
| `check()` | find missed and stuck runs, send alerts, retry alerts no channel accepted, prune. Returns `{ checkedAt, jobs, alerts, pruned }`. Concurrent calls share one check. A job that cannot be evaluated is reported to `onError` and listed as `failing`; the rest are checked as usual |
| `startChecking(every = "1m")`, `stop()` | check on an interval, starting about a second after `startChecking()`. The interval is held between 5 seconds and about 24.8 days (the longest delay a timer keeps), so a shorter one checks every 5 seconds and a longer one about every 24.8 days. With `deliver: "check"`, it warns once on the console that these checks send nothing and another process must. (A job's `start()` opens a run; this starts the checks.) |
| `routes(options?)` | the [dashboard and API](/docs/dashboard/) handlers; see [below](#routes) |
| `jobs()` | every job's summary, without alerting |
| `jobsWithRuns(limit = 20)` | every job's summary with its newest `limit` runs, read together: `{ job, runs }[]` |
| `jobSummary(name)`, `getRun(id)` | |
| `runs(name, limit = 50)` | newest first; `limit` is truncated to a whole number from 1 to 500 |
| `silence(name, duration)`, `unsilence(name)` | the silence ends on a whole millisecond, held at 2^53 - 1 ms however long it asks for |
| `forget(name)` | remove a job and its runs from the store. A job still declared in code comes back: on its next run, or at the next check or dashboard read of a process that declares it |
| `definedJobs()` | the definitions declared in this process |
| `close()` | stop the interval, wait for a check already under way, then close the store |
| `resumeRun(name, runId)` | `job(name).resume(runId)` for a job declared in this process; rejects for one that is not |
| `recordRun(run, { evaluate? })` | record a run that happened outside this process, for a source; see [below](#recordrun) |

### routes()

`cw.routes(options?)` returns `{ handler, GET, POST, DELETE }`, one fetch-style handler under four names, serving the [dashboard and API](/docs/dashboard/). It is the one way to mount the dashboard, here and in every port.

| Option | Default | |
|---|---|---|
| `token` | `CRONWATCH_TOKEN` | the bearer the routes require, and what the sign-in cookie holds a digest of. Empty or only whitespace counts as unset, here or in the variable; a value that is neither a string nor `null` throws. With none, [in development](/docs/dashboard/#development), the routes make a random token and print a sign-in link to the server log on their first request; otherwise they answer 503. `null` opts out and serves them open |
| `basePath` | `"/cronwatch"` | where the routes are mounted: it routes requests, builds links and scopes the cookie |
| `origin` | the request URL's | the public origin, such as `"https://app.example.com"`, used for the cross-site check, the sign-in redirect and cookie, and the development sign-in line. Must be an `http` or `https` URL, or the call throws |
| `trustProxy` | `false` | take the origin from the first `X-Forwarded-Proto` and `X-Forwarded-Host` instead, when present (see [behind a proxy](/docs/dashboard/#behind-a-proxy)). With neither this nor `origin`, forwarded headers are ignored |

The development sign-in line names the host only when `origin` is set or the first request's host is loopback (`localhost`, a name ending in `.localhost`, `127.0.0.0/8` or `::1`); for any other host it prints the path alone, since a client controls the `Host` header. Cross-site writes are refused, only a `Bearer` `Authorization` header is read as the token (any other scheme leaves the cookie and `?token=` to sign in), the sign-in form posts the token to `<base>/signin`, `?token=` is read only on a page `GET`, and a silence `for` that is not a duration or a number of milliseconds is a 400.

### recordRun()

`cw.recordRun(run, { evaluate? })` records a run that happened outside this process, for a [source](#exports).

- Its job must be declared first.
- Every metric must be a finite number, as with `job.metric()`; one that is not (`NaN`, `Infinity`, text) throws and nothing is recorded.
- Runs are keyed by id: a new one is inserted, a stored one still running is updated when this one is not, and anything else is left alone, so recording the same run twice changes nothing.
- A finished run is judged as if it had been wrapped here (`expect`, failures, duration, budgets) and redacted the same way.
- `evaluate: false` stores it without judging it, for history imported on first sight.
- It resolves to the alerts it sent.

## Exports

`@cronwatch/sdk`: `cronwatch`, `Cronwatch` (the client class, and its options type `CronwatchOptions`; the former spellings `CronWatch` and `CronWatchOptions` still work through 1.x, deprecated), `memory`, `custom`, `consoleChannel`, `parseDuration`, `formatDuration`, `parseSchedule`, `nextFire` (the next time a parsed schedule fires after a given time), `composeAlert`, and every type they use, including `Alert`, `AlertDraft`, `AlertDetails`, `ParsedSchedule`, `JobContext`, `RunHandle`, `StartOptions`, `RunOutcome`, `RecordRunOptions`, `Source` and `SourceHost` (the interface a source is given: `job()`, `recordRun()`, `store`, `now` and `onError`), and `FetchHandler`, `Routes` and `RoutesOptions`.

Stores: `@cronwatch/sdk/sqlite` (`sqlite`), `/postgres` (`postgres`) and `/d1` (`d1`). `/sqlite` needs `better-sqlite3` and `/postgres` needs `pg`, both optional peer dependencies; `/d1` needs nothing.

Sources: `@cronwatch/sdk/pg-cron` (`pgCron`), which reads pg_cron's jobs and runs through the pool you pass it. See [Supabase and pg_cron](/docs/supabase/).

Alert channels, one function each, named after the entry: `/slack`, `/discord`, `/webhook`, `/resend`, `/postmark`, `/sendgrid`, `/mailgun`, `/ses`, `/twilio`, `/sentry`, `/honeybadger`, `/datadog`, `/rollbar`, `/bugsnag` and `/newrelic`. None needs a dependency. `/webhook` also has `signature(secret, body)`, for a receiver checking the [signature header](/docs/alerts/#webhook). See [Alerts](/docs/alerts/).

Each entry point is named after the product it stores in, sends to, reads or triages with, and exports that one function, its options type and nothing else that is promised.

Triage: `@cronwatch/sdk/anthropic` (`anthropic`) needs `@anthropic-ai/sdk`, which you install yourself.

The core, `/d1`, `/pg-cron` and every channel use only `fetch` and Web Crypto, so they run on Node 22 or newer, Cloudflare Workers, Deno and Bun. `/sqlite`, `/postgres` and `/node` need Node.

`@cronwatch/sdk/node`: `toNodeHandler(fetchHandler, { trustProxy?, basePath? })` turns a fetch-style handler (the routes, or a job's `handler()`) into `(req, res, next?)` for `http.createServer`, Express or Connect, NestJS and Firebase `onRequest`; `toKoaMiddleware(fetchHandler, options?)` does the same for Koa; `toRequest(req, options?)` and `writeResponse(res, response)` are the two halves. Node only; see [Express, Koa and plain Node servers](/docs/node/#express-koa-and-plain-node-servers).

## Deprecated

These names still work, and do exactly what their replacements do, through every 1.x release; each is marked `@deprecated`, so an editor strikes it through, and each goes in 2.0.

| Deprecated | Use instead |
|---|---|
| `CronWatch`, `CronWatchOptions` | `Cronwatch`, `CronwatchOptions`: the spelling every port uses |
| `createRoutes(cw, options)` | `cw.routes(options)` |
| `cw.start(every)` | `cw.startChecking(every)`: a job's `start()` opens a run, so the client's is named for what it starts |

These were exported by accident. Each is marked `@deprecated` too, still works, and is no longer exported from 1.0: `hmacSha256Hex` from `/webhook` (use `signature(secret, body)`, the name every port uses), and, internal to their entry points, `MAX_SEGMENTS`, `MAX_BODY`, `smsSegments` and `smsBody` from `/twilio`; `parseDsn` from `/sentry`; `DESCRIPTION_MAX`, `embedDescription`, `codeBlockSafe` and `escapeMarkdown` from `/discord`; `PG_CRON_HOLD_MS`, `pgCronSchedule`, `pgCronJobName` and `pgCronRun` from `/pg-cron`.
