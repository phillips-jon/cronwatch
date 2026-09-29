---
title: Celery
description: Watch Celery tasks and beat schedules with no task changes: every run recorded from Celery's signals, retries and lost workers handled, and a check task for beat.
order: 3.255
---

# Celery

`cronwatch.celery` watches a Celery app's tasks through Celery's own signals, so no task changes. Every task beat schedules becomes a CronWatch job with beat's schedule, each run is recorded in the worker that ran it, and a check task, scheduled with beat, reports the runs that never happened.

```bash
pip install "cronwatch-sdk[celery]"
```

Celery 5.5 or newer. [django-celery-beat](https://github.com/celery/django-celery-beat) is read too when it is installed.

## Install it

```python
# celery_app.py
from celery import Celery
from celery.schedules import crontab
import cronwatch.celery
from myapp.monitoring import cw          # your cronwatch.Cronwatch client

app = Celery("myapp", broker="redis://localhost:6379/0")
app.conf.timezone = "UTC"
app.conf.beat_schedule = {
    "nightly-report": {"task": "reports.build", "schedule": crontab(hour=2, minute=0)},
    "sync-crm": {"task": "crm.sync", "schedule": 900.0},
    "cronwatch-check": {"task": "cronwatch.celery.check", "schedule": 300.0},
}

cronwatch.celery.install(app, client=cw, grace="15m")
```

That is all. Each beat entry's task is a job named after the task, with beat's schedule: a `crontab` becomes the same cron expression in the app's zone (checked against Celery's own idea of when it is due, around clock changes too), and an interval becomes `every 15m`. Options given to `install` (`grace`, `timeout`, `failures_before_alert` and the rest) apply to every job it declares. The `cronwatch-check` entry runs the check every five minutes; schedule it once for the whole deployment, not once per worker.

Inside a watched task, `cronwatch.current()` is the run's context, so a task can log and report metrics:

```python
import cronwatch

@app.task(name="reports.build")
def build():
    path = render_report()
    cronwatch.current().log("Report written:", path)
    cronwatch.current().metric("pages", 14)
```

`client=` is a client or a function returning one. In a Django project that uses [`cronwatch.django`](/docs/django/), leave it out and the settings' client is used; otherwise it is `cronwatch.client()`.

## Tasks beat does not schedule

A task started some other way (by your code, a webhook, another task) is watched when you ask:

```python
from cronwatch.celery import cronwatch_task

@app.task
@cronwatch_task(timeout="30m", expect="imported")
def import_orders(batch_id): ...
```

`@cronwatch_task(**options)` goes below `@app.task` on the function or above it on the task, and takes a job's options and `name=`; its own options win over `install`'s, and its `schedule` replaces beat's. A job is named after its task unless `name=` gives it another name, such as a shorter one for the dashboard: `@cronwatch_task(name="import-orders")`. A job name is 1 to 120 letters, digits, `.`, `_`, `:` or `-`, starting with a letter or digit. `install(app, tasks={"orders.import": {"timeout": "30m"}})` does the same without touching the task, and `exclude=` leaves out beat entries by key or tasks by name. `celery.backend_cleanup` is never a job.

## Retries, failures and lost workers

A task that raises still raises on to Celery, so its retries, error handlers and result backend see it unchanged.

Each attempt is a run of its own: an attempt that ends in `self.retry()` is a failed run with the error that caused it, and the attempt that finally succeeds closes the alert with a recovery. So a task that fails, retries and then succeeds sends one failed alert and one recovery, not one per attempt. To ride through a few retries without any alert, set `failures_before_alert` to the number of attempts you are willing to lose.

A run whose worker process is lost is failed by the worker's main process, which Celery tells: a hard time limit, `WorkerLostError`, a revoke with `terminate=True`, a task cancelled when the broker connection dropped. Celery's `Ignore` is an ok run and `Reject` a failed one. A run Celery never reports (a task requeued after the whole worker died) is marked stuck by a check once the job's `timeout` has passed.

## Schedules from django-celery-beat

When django-celery-beat is installed, its enabled recurring `PeriodicTask` rows are read as schedules too, each in its own zone, and they win over `beat_schedule` entries of the same name, as its scheduler copies those into the table. Clocked and one-off rows are not schedules. `install(app, django_celery_beat=False)` turns this off.

A schedule that cannot be read (a solar schedule, one task scheduled by several entries, a time that daylight saving skips) is reported once through `on_error`, and the task is still watched, without a schedule, so its failures still alert.

## Stores and pools

Every worker process records to the store, so use one they all share. With workers on more than one machine, that is [Postgres](/docs/python/#stores). With every worker on one machine, a SQLite file on its local disk works too (not on a network share, where SQLite's locking cannot be trusted).

The prefork pool is fine: each child opens its own connection. Do not use the in-memory store: each process would have its own history, and nothing would notice a missed run.

## Tests

With `task_always_eager`, or `task.apply()`, a task runs in the test process and its run is recorded the same way, so a test can assert on `cw.runs("reports.build")`.
