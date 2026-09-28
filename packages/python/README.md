# cronwatch-sdk

Cron and scheduled-job monitoring that lives inside your Python app. Wrap a job once; every run is recorded in a database you already have, and you are told when a run is missed, fails, gets stuck, runs slow or goes over budget. No server to run, no account to make.

This is the Python port of [`@cronwatch/sdk`](https://www.npmjs.com/package/@cronwatch/sdk): the same rules, the same alert text and the same stored rows, so a Python process, a Node process and a Ruby process can share one database, and [`@cronwatch/mcp`](https://www.npmjs.com/package/@cronwatch/mcp) works against any of them.

Docs: [cronwatch.dev](https://cronwatch.dev/docs/)

## Install

```bash
pip install cronwatch-sdk        # or: uv add cronwatch-sdk
```

The import name is `cronwatch`. Python 3.11 or newer, and no dependencies: cron expressions are read by a port of [croner](https://github.com/hexagon/croner) (the parser the SDK uses), zones come from the standard library's `zoneinfo`, and the SQLite store uses the standard library's `sqlite3`. On Windows, which has no zone database of its own, install `cronwatch-sdk[tzdata]`.

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

cw.start()  # checks for missed and stuck runs every minute, in a daemon thread
```

A run is recorded when the block ends; an exception inside it is recorded as the failure and raised again. A function works the same way, as a decorator (each call is a run, and `cronwatch.current()` is its context) or passed to `run()`, which returns what the function returns:

```python
@nightly.monitor
def build_report() -> None:
    cronwatch.current().log("Report written")

nightly.run(lambda ctx: sync_accounts(ctx))
```

A script run from crontab exits when it is done, so instead of `start()`, add a second crontab line that declares the jobs and calls `cw.check()` every five minutes. `cronwatch.configure(...)` makes the process's client once, and `cronwatch.client()` hands it out.

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

`job(name, ...)`: `schedule` (five or six field cron, a nickname such as `"@hourly"`, or `"every 5m"`), `timezone` (IANA; default the process's), `grace` (default `"10m"`), `timeout` (default `"1h"`), `max_duration`, `budget` (`{"metric": ceiling}`), `expect` (a string the output must contain, a compiled `re` pattern it must match, or a function), `failures_before_alert` (default 1), `description`, `tags`. Durations are strings like `"1h30m"`, milliseconds, or `datetime.timedelta`.

`Cronwatch(...)`: `store`, `alerts`, `triage` (a function returning a short diagnosis added to each alert), `sources`, `retention` (default `"30d"`), `defaults`, `redact` (secrets are blanked from output and errors by default; pass your own function, or `False`), `deliver` (`"check"` queues alerts for another process's check to send), `on_error` (store and channel failures; default the `cronwatch` logger), `now`.

`check()`, `jobs()`, `jobs_with_runs()`, `job_summary(name)`, `runs(name)`, `get_run(id)`, `silence(name, "2h")`, `unsilence(name)`, `forget(name)`, `record_run(run)`, `start()`, `stop()`, `close()`.

### Stores

- `cronwatch.stores.MemoryStore()`, the default: forgets on restart.
- `cronwatch.stores.SqliteStore(path, prefix="cronwatch_")`: one file, WAL mode. The tables, statements and JSON are the SDK's SQLite store's, byte for byte, so a Node process using `@cronwatch/sdk/sqlite` on the same file sees the same jobs, runs and state.
- `cronwatch.stores.postgres.PostgresStore(url, prefix="cronwatch_")` (`pip install "cronwatch-sdk[postgres]"`, psycopg 3): the SDK's Postgres tables and statements. It reads `DATABASE_URL` when given no URL, and writes through a connection of its own, so a run recorded inside the app's transaction survives a rollback. `pool=` takes a psycopg_pool pool instead.

### Alert channels

In `cronwatch.alerts`, standard library only, each the SDK's request for request:

```python
from cronwatch.alerts import Slack, Resend, Twilio, Sentry

alerts = [
    Slack(os.environ["SLACK_WEBHOOK_URL"], link=lambda a: f"https://app.example.com/cronwatch/jobs/{a.job}"),
    Resend(api_key=os.environ["RESEND_API_KEY"], from_="alerts@example.com", to="ops@example.com"),
    Twilio(account_sid=..., auth_token=..., from_="+15005550006", to=["+15551110000"]),
    Sentry(dsn=os.environ["SENTRY_DSN"]),
]
```

`Slack`, `Discord` and `Webhook` (the alert as JSON, signed with `secret=`), the email providers `Resend`, `Postmark`, `Sendgrid`, `Mailgun` and `Ses` (signed with SigV4, no AWS SDK), `Twilio` for SMS, and the trackers `Sentry`, `Honeybadger`, `Datadog`, `Rollbar`, `Bugsnag` and `NewRelic`. Requests time out after ten seconds, redirects are refused rather than followed, and a provider's error never quotes a key.

### Triage and pg_cron

`cronwatch.triage.anthropic.AnthropicTriage(context="A Django app on Fly.io.")` (`pip install "cronwatch-sdk[anthropic]"`), passed as `triage=`, adds Claude's short diagnosis to each alert but recoveries.

`cronwatch.sources.pgcron.PgCron(url_or_connection, prefix="db:")`, passed in `sources=[...]`, watches pg_cron's jobs: each is declared with its schedule, and the rows of `cron.job_run_details` are copied in as runs on every check, so missed, failed, stuck and slow pg_cron jobs alert like any other.

### The dashboard

`cw.routes(token=...)` is the SDK's dashboard and JSON API, page for page: a board of every job with its last day drawn as a timeline, a page per job with its week and runs, silence and forget, and the JSON that `@cronwatch/mcp` reads. It is a WSGI app, and its `.asgi` is the same routes as an ASGI app:

```python
from werkzeug.middleware.dispatcher import DispatcherMiddleware
app.wsgi_app = DispatcherMiddleware(app.wsgi_app, {"/cronwatch": cw.routes()})   # Flask
app.mount("/cronwatch", cw.routes().asgi)                                         # FastAPI, Starlette
```

Send the token as `Authorization: Bearer <token>`, or open the dashboard once with `?token=<token>` and a cookie keeps you signed in. It defaults to `$CRONWATCH_TOKEN`; with none set the routes answer 503, except in development (`CRONWATCH_ENV=development`), where they make one and print a sign-in link. `token=None` serves them open, behind your own auth. `/api/check` also takes the client's `cron_secret` as a bearer, so a platform cron can run checks. Behind a proxy, pass `origin="https://app.example.com"` (or `trust_proxy=True` when the proxy sets `X-Forwarded-Proto` and `X-Forwarded-Host`).

### Django

`pip install "cronwatch-sdk[django]"` (Django 5.2 or newer), then:

```python
# settings.py
INSTALLED_APPS = [..., "cronwatch.django"]
CRONWATCH = {
    "STORE": "myapp.monitoring.make_store",   # a store, or a dotted path to one or to what makes one
    "ALERTS": [Slack(webhook_url=os.environ["SLACK_WEBHOOK_URL"])],
    "TOKEN": os.environ["CRONWATCH_TOKEN"],
}

# urls.py
urlpatterns = [..., path("cronwatch/", include("cronwatch.django.urls"))]
```

`CRONWATCH` takes the client's options in upper case (`STORE`, `ALERTS`, `TRIAGE`, `SOURCES`, `CRON_SECRET`, `RETENTION`, `DEFAULTS`, `REDACT`, `DELIVER`, `ON_ERROR`), or `CLIENT` for a client you made yourself, and the dashboard's (`TOKEN`, `BASE_PATH`, `ORIGIN`, `TRUST_PROXY`). `cronwatch.django.client()` is the client made from them, and `cronwatch.client()` hands out the same one. `python manage.py cronwatch_check` runs one check, for cron to call every few minutes. `DEBUG` is the environment unless `CRONWATCH_ENV` says otherwise: with it on and no token set, the dashboard makes one and prints its sign-in link to the runserver log.

The Celery and APScheduler integrations and an async client follow in a later release; [DESIGN.md](DESIGN.md) has the plan.

## Testing

From this directory, with [uv](https://docs.astral.sh/uv/):

```bash
uv run pytest                    # the Python uv picks
uv run --python 3.11 pytest      # any of 3.11 to 3.14
```

`tests/test_conformance.py` replays the cases in the repository's `conformance/` directory, generated from the TypeScript SDK. `tests/test_node_compat.py` shares a SQLite file with the built SDK, and `tests/test_schedule_fuzz.py` checks thousands of generated cron expressions against croner itself; both need Node and the SDK built first (`npm ci && npm run build` at the repository root), and skip with the reason otherwise. The Postgres store's tests run when `CRONWATCH_TEST_PG` is a Postgres URL, and the pg_cron source's tests against the real extension when `CRONWATCH_TEST_PGCRON` is the URL of a Postgres with pg_cron in `cron.database_name` (CI starts both). `tests/test_web_golden.py` replays the SDK routes' answers to a fixed seed (`packages/ruby/test/web/golden.json`, which the gem replays too) and compares every page and header byte for byte. `tests/test_django.py` runs on the dev group's Django; CI runs it on each supported series with `uv run --with "django~=5.2.0" pytest` (and 6.0, 6.1). `npm run check:python` at the root runs the suite.

## License

MIT
