"""The Celery app test_celery.py runs a real prefork worker on (with Redis,
when CRONWATCH_TEST_REDIS is set): its tasks run in child processes, which
record to one SQLite file the test reads."""

from __future__ import annotations

import os
import time

from celery import Celery

import cronwatch
import cronwatch.celery
from cronwatch.stores import SqliteStore

app = Celery("cwtest", broker=os.environ["CW_BROKER"], backend=os.environ["CW_BROKER"])
app.conf.update(
    broker_connection_retry_on_startup=True,
    worker_hijack_root_logger=False,
    task_default_queue=os.environ.get("CW_QUEUE", "celery"),
    worker_prefetch_multiplier=1,
)
client = cronwatch.Cronwatch(store=SqliteStore(os.environ["CW_DB"]), alerts=[], cron_secret=None)
cronwatch.celery.install(app, client=client, tasks={"cwtest.ok": {}, "cwtest.slow": {}, "cwtest.die": {}})


@app.task(name="cwtest.ok")
def ok() -> str:
    context = cronwatch.current()
    assert context is not None
    context.log("child", os.getpid())
    return "done"


@app.task(name="cwtest.slow", time_limit=2)
def slow() -> None:
    time.sleep(30)


@app.task(name="cwtest.die")
def die() -> None:
    os._exit(1)
