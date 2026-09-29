---
title: Django
description: cronwatch-sdk in a Django app: settings, jobs in management commands, the cronwatch_check command for cron, and the dashboard under your URLs.
order: 3.25
---

# Django

`cronwatch.django` wires [cronwatch-sdk](/docs/python/) into a Django app: one settings dict, the dashboard and JSON API under a URL you choose, and a management command that looks for missed and stuck runs. It needs Django 5.2 or newer and is tested on 5.2 LTS, 6.0 and 6.1.

```bash
pip install "cronwatch-sdk[django]"
```

## Settings

```python
# settings.py
import os
from cronwatch.alerts import Slack

INSTALLED_APPS = [
    # ...
    "cronwatch.django",
]

CRONWATCH = {
    "STORE": "cronwatch.stores.postgres.PostgresStore",   # reads DATABASE_URL
    "ALERTS": [Slack(os.environ["SLACK_WEBHOOK_URL"])],
    "TOKEN": os.environ.get("CRONWATCH_TOKEN", ""),
}
```

The client's options are the keys of `CRONWATCH` in upper case: `STORE`, `ALERTS`, `TRIAGE`, `SOURCES`, `CRON_SECRET`, `RETENTION`, `DEFAULTS`, `REDACT`, `DELIVER` and `ON_ERROR`, meaning what they mean on [`Cronwatch()`](/docs/python/#api). A store, channel or source may be a dotted path, to the thing itself or to a class or function that makes it (called once, with no arguments), so settings need not import your code. `CLIENT` instead names a client your app made itself (the client, or a dotted path to it). An unknown key raises `ImproperlyConfigured`, so a typo is found at once.

The client is made from these settings the first time something asks for it, through `cronwatch.configure`, so `cronwatch.django.client()` and `cronwatch.client()` are the same client everywhere in the process. A change to `CRONWATCH` or `DEBUG`, as `override_settings` makes in a test, drops it and makes it again.

`DEBUG` stands in for the environment when none of `CRONWATCH_ENV`, `APP_ENV` and `ENVIRONMENT` is set: on is development, off is production. In development the dashboard makes a token of its own when there is none and prints its sign-in link to the console (with the host only when `ORIGIN` is set or the request's host is loopback, such as `localhost` or `127.0.0.1`; otherwise the link is a path to open on this server); in production, without a token, it answers 503 rather than serve your jobs to anyone.

## Declare and run jobs

Declare jobs in a `cronwatch_jobs.py` module in any installed app. At startup `cronwatch.django` imports that module from every app that has one, the way the admin finds `admin.py`, so each job is known before it first runs and a job that never runs at all is reported missed:

```python
# reports/cronwatch_jobs.py
from cronwatch.django import client

nightly_report = client().job(
    "nightly-report",
    schedule="0 2 * * *", timezone="UTC", grace="15m", timeout="30m",
    expect="Report written",
)
```

Then wrap the work. A job that cron runs is usually a management command:

```python
# reports/management/commands/nightly_report.py
from django.core.management.base import BaseCommand
from reports.cronwatch_jobs import nightly_report

class Command(BaseCommand):
    def handle(self, *args, **options):
        with nightly_report.run() as ctx:
            path = build_report()
            ctx.log("Report written:", path)
```

```
0 2 * * *    cd /srv/app && .venv/bin/python manage.py nightly_report
```

The run is recorded when the block ends; an exception inside it is recorded as the failure and raised again, so the command still exits non-zero. `@nightly_report.monitor` on a function, and `nightly_report.run(fn)`, work the same way, async functions included; see [Python](/docs/python/#declare-and-run-a-job) for every option. A `cronwatch_jobs` module that fails to import stops Django's startup, so a bad declaration is found at deploy rather than at 2 a.m.

Jobs that Celery runs need no declarations at all: see [Celery](/docs/celery/).

## Jobs a platform cron calls

A platform that runs jobs by calling a URL (a hosting provider's scheduler, a cron service) can call a view: `job.handler(fn).django` is a view, exempt from CSRF, that runs the job for each request carrying `Authorization: Bearer <CRON_SECRET>` and answers 401 to anything else.

```python
# urls.py
from reports.cronwatch_jobs import nightly_report
from reports.tasks import build_report

urlpatterns = [
    path("cron/nightly-report", nightly_report.handler(lambda ctx, request: build_report()).django),
]
```

The secret is the client's `CRON_SECRET` (from `CRONWATCH`, else the environment); outside development, a handler with no secret answers 503 rather than let anyone run the job. See [handler](/docs/python/#jobs-a-url-starts) for the rules.

## Look for missed runs

A job that never started records nothing, so something has to look. Add one crontab line:

```
*/5 * * * *  cd /srv/app && .venv/bin/python manage.py cronwatch_check
```

`cronwatch_check` runs the check and prints `cronwatch: checked N jobs, sent M alerts` (nothing at `--verbosity 0`). Every job in a `cronwatch_jobs` module is declared when Django starts, and every job in the store is checked from its stored definition. Run one checker per store.

A long-running process can check on its own instead: call `client().start()` once in each worker process (with Gunicorn, in its `post_fork` hook), and drop the crontab line.

## Mount the dashboard

```python
# urls.py
from django.urls import include, path

urlpatterns = [
    # ...
    path("cronwatch/", include("cronwatch.django.urls")),
]
```

Everything under the prefix goes to one view, which serves the same pages and JSON API as the TypeScript routes: the board, the last day's timeline, each job's runs, and the endpoints the [MCP server](/docs/mcp/) uses. The base path is wherever the URLs are included. The request's origin is Django's own (`request.scheme` and `request.get_host()`), so `SECURE_PROXY_SSL_HEADER` and `USE_X_FORWARDED_HOST` behind a proxy apply as they do to the rest of your app; `ORIGIN` in `CRONWATCH` pins it instead, and `TRUST_PROXY` and `BASE_PATH` are there too.

The view is exempt from Django's CSRF middleware: the dashboard's forms carry no Django token, and the routes refuse a cross-site write themselves, as the SDK's do. Sign in once with `?token=` and the browser keeps a cookie; scripts and the MCP server send the token as a bearer. Django's middleware may add headers of its own (`Cross-Origin-Opener-Policy`, `X-Frame-Options`); the dashboard's own headers and pages are unchanged. See [Dashboard and API](/docs/dashboard/) for every endpoint, and [Install it as an app](/docs/dashboard/#install-it-as-an-app) for putting it on a phone's home screen.

## Tests

With `DEBUG` off, as Django's test runner sets it, the environment reads as production: the in-memory store warns that it forgets on restart, and a dashboard with no token answers 503. Set `CRONWATCH_ENV=test` for the test run, or give the test settings a `TOKEN`, and use `override_settings(CRONWATCH={...})` to swap the store or channels per test.
