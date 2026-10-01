# cronwatch-sdk

Cron and scheduled-job monitoring that lives inside your Python app. Wrap a job once; every run is recorded in a database you already have, and you are told when a run is missed, fails, gets stuck, runs slow or goes over budget. No server to run, no account to make.

This is the Python port of [`@cronwatch/sdk`](https://www.npmjs.com/package/@cronwatch/sdk): the same rules, the same alert text and the same stored rows, so a Python process can share one database with a Node, Ruby, PHP, Go or Rust process, and [`@cronwatch/mcp`](https://www.npmjs.com/package/@cronwatch/mcp) works against any of them.

Docs: [cronwatch.dev](https://cronwatch.dev/docs/)

## Install

```bash
pip install cronwatch-sdk        # or: uv add cronwatch-sdk
```

The import name is `cronwatch`. Python 3.11 or newer, and no dependencies: cron expressions are read by a port of [croner](https://github.com/hexagon/croner) (the parser the SDK uses), zones come from the standard library's `zoneinfo`, and the SQLite store uses the standard library's `sqlite3`. On Windows, which has no zone database of its own, install `cronwatch-sdk[tzdata]`. An older, unrelated PyPI project named `cronwatch` installs a module of the same name; if `pip show cronwatch` finds it, uninstall it, or `import cronwatch` may load the wrong one.

## Use

```python
import cronwatch
from cronwatch.stores import SqliteStore

cw = cronwatch.Cronwatch(
    store=SqliteStore("./data/cronwatch.db"),
    alerts=[cronwatch.Custom("pager", lambda alert: page(alert.title, alert.message))],
)

nightly = cw.job(
    "nightly-report",
    schedule="0 2 * * *", timezone="UTC", grace="15m", timeout="30m",
    expect="Report written", budget={"cost": 2},
)

with nightly.run() as ctx:
    path = build_report()
    ctx.log("Report written:", path)   # kept with the run, shown in alerts
    ctx.metric("cost", 1.2)            # watched against budgets and baselines

cw.start_checking()  # checks for missed and stuck runs every minute, in a daemon thread
```

A run is recorded when the block ends; an exception inside it is recorded as the failure and raised again. A function works the same way, as a decorator (each call is a run, and `cronwatch.current()` is its context) or passed to `run()`, which returns what the function returns:

```python
@nightly.monitor
def build_report() -> None:
    cronwatch.current().log("Report written")

nightly.run(lambda ctx: sync_accounts(ctx))
```

Start the check in exactly one process per store, never once per Gunicorn or uWSGI worker, since two checkers can each send the same alert. A script run from crontab exits when it is done, so instead of `start_checking()`, add a second crontab line that declares the jobs and calls `cw.check()` every five minutes. `cronwatch.configure(...)` makes the process's client once, and `cronwatch.client()` hands it out.

A run that starts in one call and ends in another (a job that hands work to a queue, a webhook that reports back later) is one run too:

```python
run = nightly.start(id=batch_id)    # records a running run; a second start with this id finds it
# later, perhaps in another process
run = nightly.resume(batch_id)
run.log("sent 40 emails")
run.finish()                        # or run.fail(error), or run.finish(result="text")
```

A run that is never finished is marked stuck by the first check after the job's timeout.

### Options

`job(name, ...)`: `schedule` (five or six field cron, a nickname such as `"@hourly"`, or `"every 5m"`), `timezone` (IANA; default the process's), `grace` (default `"10m"`), `timeout` (default `"1h"`), `max_duration`, `budget` (`{"metric": ceiling}`), `expect` (a string the output must contain, a compiled `re` pattern it must match, or a function), `failures_before_alert` (default 1), `description`, `tags`. Durations are strings like `"1h30m"`, milliseconds, or `datetime.timedelta`; a duration string is at most 64 characters, and a longer one raises `ValueError`. A job name is 1 to 120 letters, digits, `.`, `_`, `:` or `-`, starting with a letter or digit.

An `expect` pattern is searched in your process by `re`, which backtracks and, like an `expect` function, has no time limit. A pattern with unbounded repeats that can match the same text (`\n*\n*x`, `(a+)+b`, even `.*x`) can take seconds or longer on a long output that does not match: anchor it, avoid a repeat next to or inside another over the same characters, or use a plain string. See [expect rules](https://cronwatch.dev/docs/conditions/#expect-rules).

`Cronwatch(...)`: `store`, `alerts`, `triage` (a function returning a short diagnosis added to each alert), `sources`, `cron_secret` (the bearer `/api/check` and a job's handler accept; default `$CRON_SECRET`), `retention` (default `"30d"`), `defaults`, `redact` (secrets are blanked from output and errors by default; pass your own function, or `False`), `deliver` (`"check"` queues alerts for another process's check to send), `on_error` (store and channel failures; default the `cronwatch` logger), `now`.

The client's methods: `job(name, ...)`, `run(name, fn=None, ...)` (a run without keeping a handle), `check()`, `jobs()`, `jobs_with_runs()`, `job_summary(name)`, `runs(name)`, `get_run(id)`, `silence(name, "2h")`, `unsilence(name)`, `forget(name)`, `resume_run(name, run_id)`, `record_run(run)`, `defined_jobs()` (the jobs declared in this process), `routes()` (the dashboard, below), `start_checking()`, `stop()`, `close()`.

### Stores

- `cronwatch.stores.MemoryStore()`, the default: forgets on restart.
- `cronwatch.stores.SqliteStore(path, prefix="cronwatch_")`: one file, WAL mode. The tables, statements and JSON are the SDK's SQLite store's, byte for byte, so a Node process using `@cronwatch/sdk/sqlite` on the same file sees the same jobs, runs and state.
- `cronwatch.stores.postgres.PostgresStore(url, prefix="cronwatch_")` (`pip install "cronwatch-sdk[postgres]"`, psycopg 3.2 or newer): the SDK's Postgres tables and statements. It reads `DATABASE_URL` when given no URL, and writes through a connection of its own, so a run recorded inside the app's transaction survives a rollback. `pool=` takes a psycopg_pool pool instead.

A `prefix` is lowercase letters, digits and underscores, not starting with a digit, at most 47 characters; any other raises `ValueError`.

### Alert channels

In `cronwatch.alerts`, standard library only, each the SDK's request for request:

```python
from cronwatch.alerts import Slack, Resend, Twilio, Sentry

alerts = [
    Slack(webhook_url=os.environ["SLACK_WEBHOOK_URL"], link=lambda a: f"https://app.example.com/cronwatch/jobs/{a.job}"),
    Resend(api_key=os.environ["RESEND_API_KEY"], from_="alerts@example.com", to="ops@example.com"),
    Twilio(account_sid=..., auth_token=..., from_="+15005550006", to=["+15551110000"]),
    Sentry(dsn=os.environ["SENTRY_DSN"]),
]
```

`Slack`, `Discord` and `Webhook` (the alert as JSON, signed with `secret=`, with extra headers from `headers=`), the email providers `Resend`, `Postmark`, `Sendgrid`, `Mailgun` and `Ses` (signed with SigV4, no AWS SDK), `Twilio` for SMS, and the trackers `Sentry`, `Honeybadger`, `Datadog`, `Rollbar`, `Bugsnag` and `NewRelic` (`environment=` for Sentry, Honeybadger and Rollbar; `site=` and `tags=` for Datadog). Requests time out after ten seconds, redirects are refused rather than followed, and a provider's error never quotes a key.

### Triage and pg_cron

`cronwatch.triage.anthropic.Anthropic(context="A Django app on Fly.io.")` (`pip install "cronwatch-sdk[anthropic]"`), passed as `triage=`, adds Claude's short diagnosis to each alert. Recoveries are sent without one.

`cronwatch.sources.pgcron.PgCron(url_or_connection, prefix="db:")`, passed in `sources=[...]`, watches pg_cron's jobs: each is declared with its schedule, and the rows of `cron.job_run_details` are copied in as runs on every check, so missed, failed, stuck and slow pg_cron jobs alert like any other.

### The dashboard

`cw.routes(token=...)` is the SDK's dashboard and JSON API, page for page: a board of every job with its last day drawn as a timeline, a page per job with its week and runs, silence and forget, and the JSON that `@cronwatch/mcp` reads. It is a WSGI app, and its `.asgi` is the same routes as an ASGI app:

```python
from werkzeug.middleware.dispatcher import DispatcherMiddleware
app.wsgi_app = DispatcherMiddleware(app.wsgi_app, {"/cronwatch": cw.routes()})   # Flask
app.mount("/cronwatch", cw.routes().asgi)                                         # FastAPI, Starlette
```

Send the token as `Authorization: Bearer <token>`, or open the dashboard once with `?token=<token>` and a cookie keeps you signed in. It defaults to `$CRONWATCH_TOKEN`, and `token=None` serves the routes open, behind your own auth.

With no token set the routes answer 503, except in development, where they make one and print a sign-in link. The environment is the first of `CRONWATCH_ENV`, `APP_ENV` and `ENVIRONMENT` that holds more than spaces, trimmed and lowercased; `development`, `dev`, `local`, `test` and `testing` count as development, and `production` and `prod` as production. The link names the host only when `origin` is set or the request's host is loopback (`localhost`, `*.localhost`, `127.0.0.0/8`, `::1`; a Host such as `localhost:1@evil.example` does not count), since a client chooses it. `/api/check` also takes the client's `cron_secret` as a bearer, so a platform cron can run checks. Behind a proxy, pass `origin="https://app.example.com"` (or `trust_proxy=True` when the proxy sets `X-Forwarded-Proto` and `X-Forwarded-Host`).

### Django

`pip install "cronwatch-sdk[django]"` (Django 5.2 or newer; Django 6.0 and 6.1 need Python 3.12 or newer), then:

```python
# settings.py
INSTALLED_APPS = [..., "cronwatch.django"]
CRONWATCH = {
    "STORE": "myapp.monitoring.make_store",   # a store, or a dotted path to one or to what makes one
    "ALERTS": [Slack(webhook_url=os.environ["SLACK_WEBHOOK_URL"])],
    "TOKEN": os.environ.get("CRONWATCH_TOKEN", ""),
}

# urls.py
urlpatterns = [..., path("cronwatch/", include("cronwatch.django.urls"))]
```

`CRONWATCH` takes the client's options in upper case (`STORE`, `ALERTS`, `TRIAGE`, `SOURCES`, `CRON_SECRET`, `RETENTION`, `DEFAULTS`, `REDACT`, `DELIVER`, `ON_ERROR`), or `CLIENT` for a client you made yourself, and the dashboard's (`TOKEN`, `BASE_PATH`, `ORIGIN`, `TRUST_PROXY`). `cronwatch.django.client()` is the client made from them, and `cronwatch.client()` hands out the same one. `python manage.py cronwatch_check` runs one check, for cron to call every few minutes. `DEBUG` is the environment unless `CRONWATCH_ENV`, `APP_ENV` or `ENVIRONMENT` says otherwise: with it on and no token set, the dashboard makes one and prints its sign-in link to the runserver log.

Declare jobs in a `cronwatch_jobs.py` module in any installed app: it is imported at startup, so `cronwatch_check` knows every job before it first runs and reports one that never does.

```python
# reports/cronwatch_jobs.py
from cronwatch.django import client

nightly = client().job("nightly-report", schedule="0 2 * * *", grace="15m")
```

### Async

A job runs an `async def` the same ways: `async with job.run() as ctx`, `@job.monitor` on an async function (each await is a run), or `await job.run(fn)`. The store is used from a worker thread, so the event loop never waits on it. For an app that is async throughout, `cronwatch.aio.AsyncCronwatch` takes the same options and has the client's methods as coroutines (`await cw.check()`, `await cw.runs("nightly-report")`), with `job.start()`, `flush()` and `finish()` awaited too; `AsyncCronwatch(cronwatch.client())` shares a synchronous client.

### Celery

`pip install "cronwatch-sdk[celery]"` (Celery 5.5 or newer), then, where the app is made:

```python
import cronwatch.celery
from celery.schedules import crontab

app.conf.beat_schedule = {
    "nightly-report": {"task": "proj.tasks.nightly_report", "schedule": crontab(hour=2, minute=0)},
    "cronwatch-check": {"task": "cronwatch.celery.check", "schedule": 300},
}
cronwatch.celery.install(app, grace="15m")
```

Every task beat schedules becomes a job named after the task, with beat's schedule (crontabs in Celery's `timezone`, intervals as `every <n>`), read from `beat_schedule` and, when installed, django-celery-beat's table. No task changes: each run by a worker is recorded through Celery's signals, and `cronwatch.current()` is its context inside the task. A task that raises is recorded as failed and raises on to Celery as before. Every attempt is a run, so a task that retries opens one failed alert and the attempt that succeeds recovers it (`failures_before_alert=3` waits for three in a row). A worker process lost under a task (a hard time limit, a revoke with terminate) has its run failed by the worker. Per-task options, and `name=` for a job name other than the task's, go below `@app.task`:

```python
@app.task
@cronwatch.celery.cronwatch_task(timeout="2h", expect="Report written")
def nightly_report(): ...
```

A schedule CronWatch cannot read exactly (a solar schedule, one task scheduled by several entries, a time that daylight saving skips) is reported to `on_error` and the task is watched without one. `cronwatch.celery.check`, scheduled with beat once for the deployment, declares every watched job and runs a check. With the prefork pool use a store the processes share (SQLite or Postgres). The client is `install(client=...)`, else the Django integration's, else `cronwatch.client()`.

### APScheduler

`pip install "cronwatch-sdk[apscheduler]"` (APScheduler 3.10 or newer; 4 is a pre-release and not supported yet):

```python
import cronwatch.apscheduler

scheduler.add_job(nightly_report, "cron", hour=2, id="nightly-report")
cronwatch.apscheduler.watch(scheduler, grace="15m", jobs={"nightly-report": {"timeout": "2h"}})
cw.start_checking()  # checks every minute, in a thread
```

Every job is declared, named after its id, with its trigger as the schedule (cron triggers in their zone, intervals as `every <n>`). A job added, rescheduled or removed later is followed. `jobs=` gives options per job, by id; `exclude=` leaves jobs out, by id or name.

Each run is recorded from APScheduler's events: a string it returns is the output, and an exception fails it. APScheduler tells a listener nothing while a job runs, so `cronwatch.current()` is `None` inside the job: return the text to record.

### A job run by a URL

For a platform cron that calls a URL (Vercel's crons, Cloud Scheduler, a Lambda function URL), `job.handler(fn)` runs `fn(ctx, request)` for each request carrying `Authorization: Bearer $CRON_SECRET` and answers with how it went, as the SDK's `handler()` does:

```python
cron = nightly.handler(lambda ctx, request: build_report(ctx))

path("api/cron/nightly", cron.django)                                  # Django (exempt from CSRF)
app.add_url_rule("/api/cron/nightly", view_func=cron.flask)            # Flask
app.add_route("/api/cron/nightly", cron.starlette)                     # Starlette, FastAPI
app = cron.wsgi   # or cron.asgi: the handler as the whole app
lambda_handler = cron.aws_lambda                                       # AWS Lambda: API Gateway or a function URL
```

It answers `{"ok", "job", "run", "status", "durationMs"}` with 200 or 500, 401 without the secret, and 503 when no secret is set outside development (`secret=None` lets anyone run it). A function that returns a response is answered with it, and, as for any run, a response of 400 or more fails the run. An `async def` makes an async handler. On Lambda, `cron.aws_lambda(event, context)` reads the bearer from a REST API's, an HTTP API's or a function URL's event, hands `fn` the event, and answers with the proxy result (`{"statusCode", "headers", "body", "isBase64Encoded"}`); a function may return a proxy result of its own. A function invoked directly (EventBridge Scheduler) gets an event with no headers, and IAM already decides who may invoke it, so give that handler `secret=None`.

## Testing

From this directory, with [uv](https://docs.astral.sh/uv/):

```bash
uv run pytest                    # the Python uv picks
uv run --python 3.11 pytest      # any of 3.11 to 3.14
```

`tests/test_conformance.py` replays the cases in the repository's `conformance/` directory, generated from the TypeScript SDK. `tests/test_node_compat.py` shares a SQLite file with the built SDK, and `tests/test_schedule_fuzz.py` checks thousands of generated cron expressions against croner itself; both need Node and the SDK built first (`npm ci && npm run build` at the repository root), and skip with the reason otherwise. The Postgres store's tests run when `CRONWATCH_TEST_PG` is a Postgres URL, and the pg_cron source's tests against the real extension when `CRONWATCH_TEST_PGCRON` is the URL of a Postgres with pg_cron in `cron.database_name` (CI starts both). `tests/test_web_golden.py` replays the SDK routes' answers to a fixed seed (`packages/ruby/test/web/golden.json`, which the gem replays too) and compares every page and header byte for byte. `tests/test_django.py` runs on the dev group's Django; CI runs it on each supported series with `uv run --with "django~=5.2.0" pytest` (and 6.0, 6.1). `tests/test_celery.py` runs tasks eagerly and on a real worker in the test process; with `CRONWATCH_TEST_REDIS` set to a Redis URL (CI starts one) it also runs a prefork worker whose children record to one SQLite file. `npm run check:python` at the root runs the suite.

## License

MIT
