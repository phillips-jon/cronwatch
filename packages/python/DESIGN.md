# The Python port

`packages/python` is `cronwatch-sdk` on PyPI (import name `cronwatch`; the name `cronwatch` on PyPI belongs to an abandoned project): the same library as `@cronwatch/sdk`, for Python apps. It is a port, not a new design, made the way the Ruby gem was (see `packages/ruby/DESIGN.md`). The TypeScript SDK is the source of truth for every behaviour, message and stored byte; when the two disagree, the Python side is wrong.

## Rules

- Python 3.11 or newer (`enum.StrEnum`, `zoneinfo`, `sqlite3` error names). The core has no runtime dependencies. Cron parsing and fire times are a port of croner 10 (`_cron.py`), zones come from the standard library's `zoneinfo`, and the SQLite store uses the standard library's `sqlite3`. On Windows, which has no zone database, `pip install "cronwatch-sdk[tzdata]"`.
- Everything else is optional and loaded only from its own module, each raising an `ImportError` that names the package to add when it is missing (from phase 2 on): `cronwatch.stores.postgres` (psycopg 3), `cronwatch.django`, `cronwatch.celery`, `cronwatch.apscheduler`, `cronwatch.triage.anthropic` (anthropic), `cronwatch.web`.
- Times are `int` epoch milliseconds everywhere, as in the SDK and the gem, so `evaluate` ports line for line and stored rows are identical.
- Python names are snake_case (`failures_before_alert`, `max_duration`, `started_at`). Run statuses, conditions, alert types and health are `StrEnum`s whose values are the wire strings (`Condition.OVER_BUDGET == "over_budget"`), so they compare equal to plain strings, hash like them and print as them. Anything that leaves the process (store rows, JSON columns, alert JSON) uses the SDK's exact camelCase field names, key order and string values, so a Node, a Ruby and a Python process can share one database and `@cronwatch/mcp` works against any of them.
- JSON is written by `_js.dumps`, which is `JSON.stringify` byte for byte: numbers as JavaScript prints them (`2` not `2.0`, `1e-7`, `1e+21`), integer-like keys first in ascending order and the rest as inserted, only control characters, quotes, backslashes and lone surrogates escaped. `to_dict()` on every type is its JSON shape in the SDK's key order; `from_dict()` reads camelCase or snake_case keys.
- Alert titles and messages are the SDK's text, character for character. `JobDefinition` keeps its fields as given, in order (defaults, then options as given, then `name`, and a stored `expect` last), including fields a newer writer added, so the stored definition is the SDK's JSON.
- Lengths and cuts are in UTF-16 code units, as JavaScript counts them (`_js.length16`, `head16`, `tail16`). A cut through a surrogate pair leaves U+FFFD where JavaScript would keep a lone surrogate, which is the character that surrogate becomes once written out as UTF-8 (to a store, a hash, a network), so the stored bytes are the same.
- Secret redaction uses the SDK's patterns, written so Python's `re` matches exactly what JavaScript's matches: `re.ASCII` keeps `\b` and the classes to ASCII, JavaScript's `\s` is spelled out, case-insensitive words are spelled `[Ss][Ee]...` (ASCII-only folding, as JavaScript's `/i` has it here), and text with characters outside the Basic Multilingual Plane is matched as surrogate pairs, then put back together.
- Every condition opens once and closes with a recovery. No repeat alerts. A job whose schedule is removed while missed is open has missed closed by the next check with a recovery of its own (`reason: "unscheduled"`).
- A job's function may raise anything. An `Exception` is recorded as the failure and raised again; anything outside it (`KeyboardInterrupt`, `SystemExit`, `GeneratorExit`) is recorded as a failed run (`Interrupted: KeyboardInterrupt`) and raised again, so no run is left `running` to be reported stuck later. The store failing never stops a job: store errors go to `on_error`, and the job's own outcome is returned or raised.
- An error is written `Name: message` and up to five frames, innermost first, each `    at function (file:line)`, as a JavaScript stack reads.
- The environment is read in one place, `_env.py`: the first of `CRONWATCH_ENV`, `APP_ENV` and `ENVIRONMENT` that is set (the SDK reads `NODE_ENV`). It only decides whether the in-memory store warns that it forgets on restart.
- A client survives a fork (gunicorn, Celery's prefork pool): it notes its pid, and in a child it starts with fresh locks, no check in flight and no interval thread, so `start()` and `check()` work there.
- No em or en dashes anywhere, as in the rest of the repo.

## Layout

```
packages/python/
  pyproject.toml  README.md  LICENSE  DESIGN.md
  src/cronwatch/
    __init__.py      Cronwatch, configure() and client(), current(), the public names, __version__
    py.typed
    _js.py           JavaScript's numbers, JSON.stringify, trim, \s, UTF-16 lengths, Date.UTC and toISOString
    _env.py          the environment
    _zone.py         zoneinfo zones (case-insensitive, as Intl), croner's wall-clock arithmetic (fromTZ)
    _cron.py         croner: CronPattern (the reading of an expression, its checks and messages) and CronDate (the walk)
    types.py         Run, JobState, StoredJob, JobDefinition, Alert, AlertDraft, JobSummary, CheckResult, the StrEnums
    duration.py      "15m", "1h30m", timedelta: parse and format
    stats.py         percentiles
    output.py        the output cap, error messages, secret redaction
    schedule.py      parse_schedule, next_fire, expectation, run_covers (schedule.ts)
    evaluate.py      the alert rules, pure functions (evaluate.ts)
    format.py        alert titles and messages
    serialize.py     stored definitions, expect rules
    job.py           JobContext (log, metric, signal), RunRecorder, AbortSignal, current()
    run_handle.py    RunHandle: a run started by job.start() or found by job.resume(), finished later
    alerts.py        the channel protocol, ChannelContext, Console, Custom
    client.py        Cronwatch and JobHandle: job, run, check, start/stop, silence, forget, jobs, runs, record_run
    stores/
      __init__.py    the Store protocol, MemoryStore, SqliteStore
      memory.py
      _sql.py        sql.ts: the schema, statements, parameters and row mapping, text for text
      sqlite.py
  tests/
    test_conformance.py   replays conformance/*.json
    test_client.py, test_client_hardening.py, test_start_finish.py   the SDK's client tests
    test_stores.py        the store conformance test, memory and SQLite
    test_node_compat.py   one SQLite file shared with the built SDK (tests/node_store.mjs)
    test_schedule_fuzz.py generated expressions answered by croner itself (tests/schedule_fuzz.mjs)
```

## The Python API

```python
import cronwatch
from cronwatch.stores import SqliteStore

cw = cronwatch.Cronwatch(
    store=SqliteStore("./data/cronwatch.db"),   # default: MemoryStore()
    alerts=[cronwatch.Custom("pager", page)],    # default: [Console()]
    retention="30d",
)
# or cronwatch.configure(...) once, and cronwatch.client() wherever it is needed

nightly = cw.job("nightly-report",
    schedule="0 2 * * *", timezone="UTC", grace="15m", timeout="30m",
    expect="Report written", budget={"cost": 2}, failures_before_alert=1)

with nightly.run() as ctx:            # a block
    ctx.log("Report written:", path)
    ctx.metric("cost", 1.2)

@nightly.monitor                      # a function: each call is a run
def build_report():
    cronwatch.current().log("Report written")

nightly.run(lambda ctx: work(ctx))    # a function taking the context; returns what it returns

cw.check()          # finds missed and stuck runs, retries undelivered alerts, prunes; a CheckResult
cw.start()          # a daemon thread that checks every minute (long-running processes)
cw.silence("nightly-report", "2h")
```

`job(name, **options)` refuses an unknown option with `TypeError` and a bad value with `ValueError` (the SDK's messages). `run(fn)` and the decorator return what the function returns and raise what it raises, after the run is recorded; a returned string is the output when nothing was logged. `cronwatch.current()` is the run in progress in this thread (a `contextvars` variable, so it follows a task too). Options take durations as strings, milliseconds or `datetime.timedelta`, and `expect` as a string, a compiled `re.Pattern` (searched) or a function; a stored `timedelta` is written as its milliseconds and a pattern as JavaScript's `/source/flags`. `cw.run(name, fn, **options)` declares and runs. `defaults=` takes grace, timeout, timezone and failures_before_alert.

Sync is the base, since Celery tasks, Django management commands and cron scripts are sync. The async variant (phase 4) is `cronwatch.aio`: `AsyncCronwatch` with the same methods as coroutines, `async with job.run()` and an async `@job.monitor`, sharing `evaluate`, `format`, `schedule`, `output` and the SQL text with the sync client. Everything with a side effect lives in `client.py` and the stores, and the pure parts take no store, so the async client is a second copy of the orchestration only. Until then a coroutine function passed to `run()` or `monitor()` is refused with `TypeError`, rather than recorded as a run that finished at once.

## Runs that span calls

`job.start(trigger=None, id=None)`, `job.resume(run_id)` and `cw.resume_run(name, run_id)` are the SDK's `start()`, `resume()` and `resumeRun()`, and return a `RunHandle`: `id`, `job`, `started_at`, `active`, `log`, `metric`, `metrics`, `flush()`, `finish(outcome=None, *, result=, error=)` and `fail(error)`. An outcome is None or `{"status": "ok"}` (ok), `{"error": e}` or `error=e` (failed, written like an error `run()` caught), or a string, `{"result": x}` or `result=x`, treated like `run()`'s return value. The SDK's other outcome, a `Response` of 400 or more failing the run, has no counterpart until the web phase.

The client's side follows `client.ts`: a start with an id checks it (the SDK's messages, including the reserved `pgcron:` prefix) and holds a per-process lock keyed by the job and the id while it reads the store and inserts, so two starts with one id at once record one run, and another job's start with that id fails as it would one call later. `finish()` reads the stored run again, joins the stored output with the handle's (capped) and merges metrics (the handle's win), then judges it with the same code as `run()`. `flush()` redacts the lines it appends and writes only over a row still running and of this job (`update_run_if`); when it cannot, the handle keeps the lines for `finish()`, and it keeps the first 16 KB of what it flushed so `expect` at finish sees an early line. The store never raises out of `start`, `resume`, `flush` or `finish`: failures go to `on_error` as `recording <job>`, `starting <job>`, `resuming <job>`, `flushing <job>` or `finishing <job>`. A store that fails during `finish()` records nothing and leaves the handle active, lines kept, so it can be called again. A finish that records nothing (`... was already finished by this handle`, `... was already finished as ok`, `... was not found`, `... belongs to job "<other>"`) is reported, never raised, and returns None.

A run is judged once, however many processes finish it: the finish is written only over a stored row still `running`, else over one still `timeout` (a check already counted it as stuck: a late failure is written but not judged, a late success is judged and recovers), through the store's `update_run_if`, one conditional `UPDATE`. Only the process whose write lands evaluates. The stuck check marks a run timed out the same way, so a finish that landed meanwhile wins. `insert_run` raises for an id already stored, the memory store included.

## Threads and state

The client is synchronous; each run's work happens in the caller's thread. Every read-modify-write of a job's state goes through `Cronwatch._update_state`: holding the job's `RLock`, it reads the state, works out the next one, and writes it only when it changed, with `version` one higher, through the store's `compare_and_set_state` against the version read. A refused write is worked out again from a fresh read, up to 10 times. A store without `compare_and_set_state` gets `set_state`. Only store reads and writes happen under the lock; alerts are sent after it is released. Concurrent `check()` calls share one check (the first caller runs it, the others wait for its result). `start()` runs checks in a daemon thread named `cronwatch-check`, the first after a second and then on the interval; a second `start()` does nothing, and one with another interval is reported to `on_error`.

## Delivery

`deliver="now"` (the default) sends each alert from the process that produced it. `deliver="check"` sends nothing: the alert is queued in the job's state (`undelivered`, at most 20, the oldest dropped first and reported) for the next check in a process that delivers now, which triages and sends it, as the SDK's `deliver: "check"` does. An alert no channel accepted is queued the same way and retried once per check, oldest first; one that no longer describes the job (`evaluate.stale_alert`) is dropped; one check spends at most 20 seconds of wall clock retrying across all jobs. Triage is tried once per alert: `Alert.triage` None with `triage_tried` True is JSON `null`, never tried again.

Each channel sends in a thread of its own with a 15 second timeout, and triage gets 25 seconds. Python cannot stop a thread, so a channel (or triage) that times out is left to finish; until it has, nothing more is sent to it (the alert counts as not delivered there, and is retried) and no second triage starts, so a hung channel holds one thread rather than one per alert.

## Channels

A channel is an object with `name` and `send(alert, context)` that raises when the alert went nowhere; a plain function works too, and one that takes only the alert is called with the alert alone. `context.on_error(e)` reports a problem that did not stop the alert (one of several recipients refusing it) as `alert channel <name>`. Phase 1 has `Console` (the default) and `Custom`. Phase 2 ports the rest (Slack, Discord, webhook, Resend, Postmark, SendGrid, Mailgun, SES, Twilio, Sentry, Honeybadger, Datadog, Rollbar, Bugsnag, New Relic) request for request, standard library only (`urllib.request`, with an injectable `http` for tests, as the gem's), replaying `conformance/channels.json`.

## Sources

`sources=` takes objects with `name` and `sync(host)`, as the SDK's `sources` does. `check()` calls each, in order, after the store is ready and before anything else; one that raises is reported as `source <name>` and the check carries on, and the alerts a sync returns are added to the check's result. The host is the client: `job`, `record_run`, `store`, `now()` and `on_error(error, where)`.

`record_run(run, evaluate=True)` is the SDK's `recordRun`: keyed by the run's id, a new run is inserted, a stored run still `running` (or `timeout`, marked by a check) is finished once this one is not running, through the same claim as a handle's finish, and anything else is left alone. A stored run of another job is left alone and reported. Before that an `ok` run is checked against `expect`, and output and error are capped, redacted and cleared of NUL. The job must be declared in this process, or it raises `ValueError`. The pg_cron source (phase 2) is `sources/pgcron.ts` line for line over psycopg, replaying `conformance/pgcron.json`.

## Keeping in step

`conformance/` at the repo root holds JSON cases generated from the TypeScript build by `scripts/conformance.mjs`. `tests/test_conformance.py` replays every case that concerns the core (duration, schedule, evaluate, format, health, output, and the store scripts against the memory and SQLite stores), comparing values as the JSON the SDK writes; `channels.json`, `triage.json` and `pgcron.json` are skipped by name until their phase, and a new fixture file fails the suite until it is replayed or skipped. A behaviour change lands in TypeScript first, `npm run conformance` regenerates the fixtures, and this package is fixed until they pass.

Croner parity is also checked against croner itself: `tests/test_schedule_fuzz.py` generates 3,000 expressions (valid and malformed, nicknames, names, ranges, steps, lists, `L`, `W`, `LW`, `#`, `?`, `+`, six fields) in zones with and without daylight saving, from times around the clock changes, and the SDK in Node must give the same error message or the same fire times. Unlike the gem, the port reads every form croner reads (`W`, `LW`, `5L` in the day of the month, a year field, a range with `#`), because it ports croner's parser rather than wrapping another.

## Storage

`SqliteStore` writes the same three tables as `packages/sdk/src/stores/sql.ts`: same names (`cronwatch_` prefix by default, the same prefix rules), same columns and types, the same `CREATE` text (so `sqlite_master` reads the same whoever created them), the same statements, and the same JSON in the JSON columns. WAL mode, `busy_timeout` 5000 and `synchronous` NORMAL, the journal mode switched with the SDK's retry of a busy database, its directory created when missing and the file with mode 0600. One connection per store, shared by threads under a lock, in autocommit mode; `delete_job` is one transaction. `tests/test_node_compat.py` has the built SDK and this store replay the same store calls into two files and compares what each reads of the other's and every column's bytes and SQLite type, and has a Node client and a Python client take turns on one file and on one job's state version.

Phase 2 adds `cronwatch.stores.postgres` on psycopg 3 with the same SQL (`?` numbered as `$n`, `JSONB`, `BIGSERIAL seq`), writing through a connection of its own so its writes never join the app's transaction.

## Web

The dashboard and JSON API (phase 3) are the SDK routes' URLs, JSON shapes, auth (bearer or cookie `CRONWATCH_TOKEN`, `CRON_SECRET` for `GET /api/check`), CSRF and CSP rules and headers, as a WSGI app and an ASGI app over one core that takes a request and returns a response, mounted in Django (`path("cronwatch/", include(...))`), Flask or FastAPI. The HTML is the SDK's, checked against the gem's golden fixture (`packages/ruby/test/web/golden.json`) so the three render the same page.

## Phases

1. This: the design, the core (duration, schedule, evaluate, stats, output, format, serialize, the client with runs, handles, sources, record_run, deferred delivery and triage hooks), the memory and SQLite stores, conformance and the SDK's client tests.
2. Stores and integrations that need no web: Postgres (psycopg 3), the alert channels, Claude triage (`anthropic`), the pg_cron source.
3. The web dashboard and JSON API, and the Django integration (settings, a management command `cronwatch_check`, the app's URLs, `DEBUG` as the environment).
4. Celery (a `@cronwatch_task` decorator or signal handlers, beat schedules read as job schedules, a check task), APScheduler (a listener recording each job's runs, its triggers as schedules), and the async client.

## Where it cannot match the SDK

- A cron expression that names a date no month has (`0 0 30 2 *`) makes croner, which walks by recursion a year at a time, run out of stack before the year 3000, so the SDK reports the job as unevaluable. The port walks in a loop and answers that the schedule never fires: no next expected time, never missed.
- Croner reads a string with a colon after its first character as a one-time date, through JavaScript's lenient `Date.parse`, so the SDK accepts `2026-12-01T00:00:00` (or even `0 2:30 * * *`) as a schedule that fires once, or never. The port refuses every such string: one that looks like an ISO date with `CronPattern: a one-time date is not supported by the Python port`, anything else with the message croner gives for text `Date.parse` cannot read (`Invalid ISO8601 passed to timezone parser.`).
- In the process's own zone (no `timezone`), a wall-clock time in a gap is found by croner's `fromTZ` rule, as it is for a named zone, where JavaScript's local `Date` uses the offset before the transition. The two agree for one-hour gaps; the conformance fixtures run in UTC.
- `handler()` (a fetch-style request handler) has no counterpart until the web phase, and so neither does a `Response` outcome.
