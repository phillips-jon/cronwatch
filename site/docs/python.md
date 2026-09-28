---
title: Python
description: cronwatch-sdk in plain Python: jobs, the check, stores, alert channels, Claude triage, pg_cron, and sharing one database with a Node or Ruby app.
order: 3.26
---

# Python

`cronwatch-sdk` is a port of `@cronwatch/sdk`, not a new design. It decides missed, failed, stuck, slow and over budget by the same rules, sends the same alert text, and writes the same rows, so a Python process, a Node process and a Ruby process can share one database and the [MCP server](/docs/mcp/) works against any of them. This page covers plain Python and the API underneath.

```bash
pip install cronwatch-sdk        # or: uv add cronwatch-sdk
```

The import name is `cronwatch` (the name `cronwatch` on PyPI belongs to an older, abandoned project). Python 3.11 or newer, with no dependencies: cron expressions are read by a port of [croner](https://github.com/hexagon/croner), the parser the SDK uses; zones come from the standard library's `zoneinfo`; the SQLite store uses the standard library's `sqlite3`. Everything else is an extra, loaded only from its own module:

| Import | For | Install |
|---|---|---|
| `cronwatch` | the client, the memory and SQLite stores, `Console` and `Custom` | `cronwatch-sdk` |
| `cronwatch.alerts` | Slack, Discord, webhook, email, SMS and error tracker channels | `cronwatch-sdk` |
| `cronwatch.stores.postgres` | the Postgres store | `cronwatch-sdk[postgres]` (psycopg 3.2 or newer) |
| `cronwatch.triage.anthropic` | Claude triage | `cronwatch-sdk[anthropic]` |
| `cronwatch.sources.pgcron` | watching pg_cron's jobs | `cronwatch-sdk` (psycopg for a connection string) |

On Windows, which has no zone database of its own, install `cronwatch-sdk[tzdata]`.

## Create one client

```python
import os
import cronwatch
from cronwatch.alerts import Slack
from cronwatch.stores import SqliteStore

cw = cronwatch.Cronwatch(
    store=SqliteStore("./data/cronwatch.db"),
    alerts=[Slack(os.environ["SLACK_WEBHOOK_URL"])],
    retention="30d",
)
```

Or configure one for the whole process and reach it anywhere with `cronwatch.client()`:

```python
cronwatch.configure(alerts=[Slack(os.environ["SLACK_WEBHOOK_URL"])])
```

`configure` takes the same options and returns the client. Configuring again replaces it and stops the old one's interval checks. `cronwatch.client()` before any `configure` is a client with the defaults (the memory store, alerts printed to the console).

## Declare and run a job

```python
nightly = cw.job(
    "nightly-report",
    schedule="0 2 * * *", timezone="UTC", grace="15m", timeout="30m",
    expect="Report written", budget={"cost": 2},
)

with nightly.run() as ctx:
    path = build_report()
    ctx.log("Report written:", path)   # kept with the run, shown in alerts
    ctx.metric("cost", 1.2)            # watched against budgets and baselines
```

The run is recorded when the block ends. An exception inside it is recorded as the failure and raised again, so your own error handling still works; that includes a `KeyboardInterrupt` or `SystemExit` that stops the block, so a run is never left running to be reported stuck later.

A function works the same way, passed to `run`, which returns what the function returns (a string it returns is the run's output when nothing was logged), or as a decorator, where every call is a run and `cronwatch.current()` is its context:

```python
rows = nightly.run(lambda ctx: sync_accounts(ctx))

@nightly.monitor
def build_report() -> None:
    cronwatch.current().log("Report written")
```

Without keeping a handle, `cw.run("nightly-report")` declares the job on first use (or again, when given options) and works the same way.

Option names are snake_case (`max_duration`, `failures_before_alert`). Durations are strings such as `"15m"` or `"1h30m"`, milliseconds, or a `datetime.timedelta`. Anything that leaves the process (store rows, webhook bodies) uses the SDK's camelCase field names, so every language reads it.

The context has `name`, `run_id`, `started_at`, `log(*parts)`, `metric(name, value)`, `metrics(dict)` and `signal`, which aborts once the job's `timeout` has passed. Nothing is interrupted: a loop that can stop early checks `ctx.aborted()`, or calls `ctx.signal.throw_if_aborted()` to raise.

## Run the check

A long-running process (a web server, a worker) checks in a daemon thread:

```python
cw.start()          # every minute; cw.start("5m") to change it
```

Calling `start` again while it runs does nothing; a different interval is reported to `on_error` and ignored, so call `stop()` first to change it. A forked child (a Gunicorn or uWSGI worker) gets a fresh client state and no check in flight; call `start` in the worker, not in the parent before it forks.

Run one checker per store: one process with `start`, or one scheduled check, not one per process. Two checkers on one database can each send the same alert.

A script run from crontab exits when it is done, so nothing inside it notices the run that never happened. Add a second crontab line that checks:

```python
# check.py
from jobs import cw   # declares every job, so a job that never ran is known

result = cw.check()
print(f"{len(result.jobs)} jobs, {len(result.alerts)} alerts")
cw.close()
```

```
0 3 * * *    cd /srv/app && .venv/bin/python backup.py
*/5 * * * *  cd /srv/app && .venv/bin/python check.py
```

`check()` returns a result with `checked_at`, `jobs`, `alerts` and `pruned`. Calls at the same time share one check.

## Stores

`cronwatch.stores.MemoryStore()` is the default. Nothing survives a restart, so a miss cannot be noticed across one, and each process has its own.

`cronwatch.stores.SqliteStore(path="./data/cronwatch.db", connection=None, prefix="cronwatch_")` keeps everything in one file, in WAL mode. The directory is made if it is missing, and the file and its `-wal` and `-shm` files are created private (mode 0600). `":memory:"` works too, and `connection=` takes an open `sqlite3` connection of your own, in autocommit mode (`isolation_level=None`). It creates its tables on first use.

`cronwatch.stores.postgres.PostgresStore(conninfo=None, pool=None, prefix="cronwatch_")` needs `cronwatch-sdk[postgres]`. With no connection string it reads `DATABASE_URL`. It writes through an autocommit connection of its own, so a run recorded inside your transaction is recorded when it happens and stays recorded if that transaction rolls back. It reconnects when the connection breaks, and a forked child opens its own rather than use the parent's. `pool=` takes a `psycopg_pool.ConnectionPool` of yours instead (anything whose `connection()` is a context manager giving a psycopg connection); `close()` leaves a pool you passed open. It creates its tables on first use, under an advisory lock, so many processes can start at once.

`prefix` names the tables (`cronwatch_jobs`, `cronwatch_runs`, `cronwatch_state`): lowercase letters, digits and underscores.

A store of your own is any object with the methods the memory store has: `upsert_job`, `get_job`, `list_jobs`, `delete_job`, `insert_run`, `update_run`, `update_run_if`, `get_run`, `list_runs`, `last_run`, `running_runs`, `get_state`, `set_state`, `compare_and_set_state`, `prune`, and optionally `init` and `close`. They mean what the [TypeScript interface](/docs/stores/#writing-a-store) says, with epoch milliseconds for every time. `update_run_if` and `compare_and_set_state` are what keep two processes on one store from judging a run twice or losing each other's updates; see [two processes, one store](/docs/stores/#two-processes-one-store).

## Alerts

```python
import os
from cronwatch import Console, Custom
from cronwatch.alerts import Slack, Discord, Webhook

Slack(os.environ["SLACK_WEBHOOK_URL"], link=lambda a: f"https://app.example.com/cronwatch/jobs/{a.job}")
Discord(os.environ["DISCORD_WEBHOOK_URL"])
Webhook("https://hooks.example.com/cronwatch", secret=os.environ.get("CRONWATCH_WEBHOOK_SECRET"))
Console()

def page(alert):
    if alert.type == "recovered":
        return
    pagerduty.trigger(summary=alert.title, details=alert.message)

Custom("pagerduty", page)
```

Every alert goes to every channel at once; a channel that raises, or takes longer than 15 seconds, goes to `on_error` and never holds up the others.

A channel is any object with `name` and `send(alert, context)` that raises when the alert went nowhere; a plain function works too, and one that takes only the alert is called with the alert alone. `context.on_error(error)` reports a problem that did not stop the alert going out (one of several recipients refusing it, say) to the client's `on_error`, as `"alert channel <name>"`.

### Email, SMS and error trackers

The SDK's provider channels are in `cronwatch.alerts` too, on the standard library alone (`urllib.request`, with SES requests signed by SigV4 and no AWS SDK):

```python
from cronwatch.alerts import (
    Resend, Postmark, Sendgrid, Mailgun, Ses, Twilio,
    Sentry, Honeybadger, Datadog, Rollbar, Bugsnag, NewRelic,
)

# Email. Each takes from_, to (one address or a list), subject_prefix and link.
Resend(api_key=os.environ["RESEND_API_KEY"], from_="CronWatch <alerts@example.com>", to="ops@example.com")
Postmark(server_token=os.environ["POSTMARK_SERVER_TOKEN"], from_="alerts@example.com", to="ops@example.com")
Sendgrid(api_key=os.environ["SENDGRID_API_KEY"], from_="alerts@example.com", to="ops@example.com")
Mailgun(api_key=os.environ["MAILGUN_API_KEY"], domain="mg.example.com", region="eu",
        from_="alerts@example.com", to="ops@example.com")
Ses(region="us-east-1", access_key_id=os.environ["AWS_ACCESS_KEY_ID"],
    secret_access_key=os.environ["AWS_SECRET_ACCESS_KEY"], from_="alerts@example.com", to="ops@example.com")

# SMS, one message per number, all at once. Recoveries are not texted unless recovered=True.
Twilio(account_sid=os.environ["TWILIO_ACCOUNT_SID"], auth_token=os.environ["TWILIO_AUTH_TOKEN"],
       from_="+15005550006", to=["+15551110000"])

# Error trackers: one issue per job and alert type.
Sentry(dsn=os.environ["SENTRY_DSN"])
Honeybadger(api_key=os.environ["HONEYBADGER_API_KEY"])
Datadog(api_key=os.environ["DD_API_KEY"], site="datadoghq.eu", tags=["env:prod"])
Rollbar(access_token=os.environ["ROLLBAR_ACCESS_TOKEN"])
Bugsnag(api_key=os.environ["BUGSNAG_API_KEY"])
NewRelic(account_id=os.environ["NEW_RELIC_ACCOUNT_ID"], api_key=os.environ["NEW_RELIC_LICENSE_KEY"])
```

`from` is a Python keyword, so the sender is `from_`. The other options are the SDK's in snake_case: `subject_prefix`, `message_stream` (Postmark), `region` (`"eu"` for SendGrid, Mailgun and New Relic; the AWS region for SES), `session_token` and `configuration_set_name` (SES), `api_key_sid`, `api_key_secret`, `messaging_service_sid` and `segments` (Twilio), `environment` and `release` (Sentry), `endpoint` (Honeybadger, Bugsnag), `host` (Datadog), `release_stage` (Bugsnag), `event_type` (New Relic), and `recovered` and `link` wherever the SDK has them. A missing key, address or account raises `ValueError` when the channel is made.

Each sends exactly the request the SDK's does: the same URL, headers and body, byte for byte (the package's tests replay the SDK's recorded requests), with the same idempotency key, event id or UUID for one alert, so a provider that deduplicates drops a resend whichever language sent it. Each request gives up 10 seconds after it starts. A refused request raises `"<Provider> <origin> answered <status>: <start of the body>"`, never the URL's path, with the channel's keys cut out of the quoted body. No channel follows a redirect, so credentials never reach another address. [Alerts](/docs/alerts/#email-sms-and-error-trackers) describes what each one sends. One difference from Node: `urllib` honours the `HTTP_PROXY` and `HTTPS_PROXY` environment variables, which Node's `fetch` ignores by default.

A webhook signs its body with `X-CronWatch-Signature: sha256=<hex>`. Verifying it in Python:

```python
import hashlib, hmac

expected = "sha256=" + hmac.new(secret.encode(), raw_body, hashlib.sha256).hexdigest()
ok = hmac.compare_digest(expected, request.headers.get("X-CronWatch-Signature", ""))
```

### Processes that cannot send

A job can run somewhere that cannot reach Slack or a mail relay: a sandboxed worker, a script without the app's secrets. Give that process `deliver="check"`:

```python
recorder = cronwatch.Cronwatch(store=PostgresStore(), deliver="check")
```

It still records and evaluates every run, but queues each alert in the store instead of sending it. The next check in a process that sends normally delivers it, with triage if that process has it. Both processes must use the same store. See [processes that cannot send](/docs/alerts/#processes-that-cannot-send).

## pg_cron

pg_cron runs jobs inside Postgres, where nothing can wrap them. `PgCron` reads what pg_cron records instead: on every check it reads `cron.job`, declares each job with its schedule, and copies new rows of `cron.job_run_details` in as runs, so a job that stops running is missed, a failed run alerts and a run that never ends is stuck.

```python
from cronwatch.sources.pgcron import PgCron
from cronwatch.stores.postgres import PostgresStore

cw = cronwatch.Cronwatch(
    store=PostgresStore(),
    sources=[PgCron(os.environ["DATABASE_URL"], prefix="db:")],
)
cw.start()
```

The first argument is a connection string, a psycopg connection or pool, or anything with `query(sql, params)` that returns rows as dicts. On a connection that is not in autocommit mode it never ends a transaction of yours. The options (`jobs`, `prefix`, `job_name`, `options`, `timezone`) and the rules for renamed jobs, runs cut off by a restart and history seen for the first time are the SDK's; see [Supabase and pg_cron](/docs/supabase/).

## Redaction

Before a run's output and error are stored, shown or sent anywhere, `redact` rewrites them. The default, `cronwatch.redact_secrets`, blanks values that look like secrets (secret-named pairs, credentials in URLs, authorization headers, private keys, JWTs, webhook URLs, and AWS, GitHub, Slack, Stripe, Google and API key formats), exactly what the SDK's default blanks. An `expect` rule is checked before redaction, so it still sees what was logged.

```python
cronwatch.Cronwatch(redact=False)                                            # keep output as logged
cronwatch.Cronwatch(redact=lambda text: re.sub(r"\d{16}", "[card]", cronwatch.redact_secrets(text)))
```

A `redact` that raises, or returns something other than a `str`, is reported to `on_error` (as `"redact"`) and the default is used for that text.

## Triage

```bash
pip install "cronwatch-sdk[anthropic]"
```

```python
from cronwatch.triage.anthropic import AnthropicTriage

cw = cronwatch.Cronwatch(triage=AnthropicTriage(context="A Flask app on Postgres, jobs run from crontab."))
```

| Option | Default | |
|---|---|---|
| `model` | `"claude-opus-5"` | any current model id |
| `effort` | `"medium"` | `"low"`, `"medium"` or `"high"` |
| `max_tokens` | `800` | a diagnosis is a paragraph |
| `context` | | a sentence about the app, so advice is specific |
| `fallbacks` | `True` | route a policy refusal to Anthropic's default fallback model inside the same request. Turn off if your account or gateway rejects the beta |
| `api_key` | what the `anthropic` package resolves, normally `ANTHROPIC_API_KEY` | |
| `client` | | a configured `anthropic.Anthropic` to use instead |

It sends the same request as the SDK's, runs only when an alert is sent (never per run, never for a recovery), and once per alert. The client waits 25 seconds for it, then sends the alert without a diagnosis and reports the timeout to `on_error`. What is sent is in [AI triage](/docs/triage/).

A triage of your own is any function that takes the context (`alert`, `recent_runs`, `signal`) and returns a string or `None`.

## API

`cronwatch.Cronwatch(...)` and `cronwatch.configure(...)`:

| Option | Default | |
|---|---|---|
| `store` | in memory | a store |
| `alerts` | console | a list of channels. `[]` sends nothing |
| `triage` | | a function returning a diagnosis |
| `sources` | | where runs this process does not wrap come from, such as [pg_cron](#pg-cron). Each is synced at the start of every check; one that raises is reported to `on_error` and the check carries on |
| `cron_secret` | `$CRON_SECRET` | the bearer the dashboard's check endpoint accepts beside the token. `""` counts as unset; `None` means none on purpose |
| `retention` | `"30d"` | how long finished runs are kept. Each job's newest run is always kept |
| `defaults` | | `grace`, `timeout`, `timezone`, `failures_before_alert` applied to every job that does not set its own |
| `redact` | secret patterns | a function applied to output and errors; `False` keeps them as logged. See [Redaction](#redaction) |
| `deliver` | `"now"` | `"check"` queues alerts for another process's check to send |
| `on_error` | the `cronwatch` logger | `lambda error, where: ...` for failures outside jobs: the store, a channel, triage |
| `now` | the system clock | a function returning epoch milliseconds; for tests |

`cw.job(name, **options)` takes `schedule` (five or six field cron, a nickname such as `"@hourly"`, or `"every 5m"`), `timezone` (IANA; the process's zone by default), `grace` (`"10m"`), `timeout` (`"1h"`), `max_duration`, `budget` (`{"metric": ceiling}`), `expect` (a string the output must contain, a compiled `re` pattern it must match, or a function), `failures_before_alert` (1), `description` and `tags`, with the rules in the [API reference](/docs/api/). A name is 1 to 120 letters, digits, `.`, `_`, `:` or `-`. Bad options raise `ValueError` when the job is declared.

The client:

| Method | |
|---|---|
| `job(name, **options)` | declare a job and get its handle |
| `run(name, fn=None, **options)` | run without keeping a handle; without `fn`, a context manager |
| `check()` | find missed and stuck runs, send alerts, retry alerts no channel accepted, prune |
| `start(every="1m")`, `stop()` | check in a daemon thread; the interval is at least 5 seconds |
| `jobs()`, `jobs_with_runs(limit=20)`, `job_summary(name)` | summaries, without alerting |
| `runs(name, limit=50)`, `get_run(run_id)` | newest first; `limit` is 1 to 500 |
| `silence(name, "2h")`, `unsilence(name)` | stop alerts for a while; state keeps updating underneath |
| `forget(name)` | remove a job and its runs |
| `resume_run(name, run_id)` | `job(name).resume(run_id)` for a job declared in this process |
| `record_run(run, evaluate=True)` | record a run that happened elsewhere, for a source; returns the alerts it sent |
| `defined_jobs()` | the definitions declared in this process |
| `close()` | stop the thread and close the store |

## Runs that span calls

A run is normally one call. Work that starts in one place and ends in another (a job that hands work to a queue, a webhook that reports completion later) can be one run too: `start` records it as running and returns a run handle, and `finish` on that handle, or on one from `resume(run_id)` in another process, ends it.

```python
sync = cw.job("partner-sync", schedule="0 * * * *", timeout="2h")

run = sync.start(id=batch_id)       # records a running run
# later, perhaps in another process
run = sync.resume(batch_id)         # or cw.resume_run("partner-sync", batch_id)
run.log("imported", count, "rows")
run.finish()                        # or run.fail(error), or run.finish(result="text")
```

`start(trigger=None, id=None)` takes your own stable id, 1 to 200 characters: a start with an id already recorded for this job records nothing and returns a handle on that run. A store that fails is reported to `on_error`, never raised. The handle has `log`, `metric`, `metrics`, `flush()` (append what is logged so far to the stored run), `finish()` and `fail(error)`, and `active()`, false once it is finished. A run is judged once however many times it is finished: a second finish, or one on a run another process finished, records nothing and is reported to `on_error`. A run that is never finished is marked stuck by the first check after the job's `timeout`, so set `timeout` to cover the whole span. The [Ruby page](/docs/ruby/#runs-that-span-calls) has the full rules, which are the same.

## Sharing a database with Node and Ruby

The SQLite and Postgres stores write the same three tables as `@cronwatch/sdk/sqlite` and `@cronwatch/sdk/postgres` and the Ruby gem's store: the same names, columns and indexes, epoch milliseconds in the time columns, and the same JSON in the JSON columns. The package's tests share a SQLite file with the built SDK and check that each side reads what the other wrote. Create the tables from any side; the others find them and leave them alone. Use the same prefix everywhere.

Each process alerts on the jobs it runs, and any side's check sees every job in the store. One dashboard shows them all, and one MCP server reads it. Give each job a name only one side uses, and run one checker for the store.

The cron reader matches croner with two exceptions, both for schedules that never make sense: a date no month has (`0 0 30 2 *`) is a schedule that never fires, where croner gives up; and a one-time date in place of a cron expression (`2026-12-01T00:00:00`) is refused.

## Kept in step

The TypeScript SDK is the source of truth. Its build generates cases (duration parsing, schedules across daylight saving, sequences of runs and checks with the alerts and state they must produce, alert titles and messages, each channel's requests, stats and health) into `conformance/` in the repository, and the Python package's tests replay every one, as the Ruby gem's do. A change of behaviour lands in TypeScript first, the cases are regenerated, and the port is fixed until they pass. Where they disagree, the port is wrong: [open an issue](https://github.com/phillips-jon/cronwatch/issues).
