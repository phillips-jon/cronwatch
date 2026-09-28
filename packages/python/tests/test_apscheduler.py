"""cronwatch.apscheduler: triggers read as schedules, and a listener that
records each job's runs from APScheduler's events, with real schedulers
(background and asyncio) and with events dispatched by hand for the orders a
busy scheduler can deliver them in."""

from __future__ import annotations

import asyncio
import threading
import time
from datetime import datetime, timedelta, timezone
from typing import Any

import pytest

pytest.importorskip("apscheduler")

from apscheduler.events import (  # noqa: E402
    EVENT_JOB_ERROR,
    EVENT_JOB_EXECUTED,
    EVENT_JOB_MISSED,
    EVENT_JOB_SUBMITTED,
    JobExecutionEvent,
    JobSubmissionEvent,
)
from apscheduler.schedulers.asyncio import AsyncIOScheduler  # noqa: E402
from apscheduler.schedulers.background import BackgroundScheduler  # noqa: E402
from apscheduler.triggers.combining import OrTrigger  # noqa: E402
from apscheduler.triggers.cron import CronTrigger  # noqa: E402
from apscheduler.triggers.date import DateTrigger  # noqa: E402
from apscheduler.triggers.interval import IntervalTrigger  # noqa: E402

import cronwatch  # noqa: E402
from cronwatch.apscheduler import ScheduleError, convert, watch  # noqa: E402

from helpers import Errors, make  # noqa: E402

UTC = "UTC"


def nightly_report() -> str:
    return "Report written"


def broken() -> None:
    raise RuntimeError("db down")


def test_cron_triggers_become_the_cron_expression_croner_reads_in_the_triggers_zone() -> None:
    def cron(**fields: Any) -> dict[str, Any] | None:
        return convert(CronTrigger(**{"timezone": UTC, **fields}), "cronwatch: job")

    assert cron(hour=2) == {"schedule": "0 2 * * *", "timezone": "UTC"}
    assert cron(minute="*/5") == {"schedule": "*/5 * * * *", "timezone": "UTC"}
    assert cron(day_of_week="mon-fri", hour=9, minute=30) == {"schedule": "30 9 * * 1-5", "timezone": "UTC"}, "Monday is APScheduler's 0"
    assert cron(day_of_week="sun", hour=0)["schedule"] == "0 0 * * 0"
    assert cron(day="1,15", day_of_week="sun")["schedule"] == "0 0 1,15 * +0", "APScheduler wants both days"
    assert cron(day="last", hour=3)["schedule"] == "0 3 L * *"
    assert cron(day="1,last", hour=5)["schedule"] == "0 5 1,L * *"
    assert cron(day="1st fri", hour=4)["schedule"] == "0 4 * * 5#1"
    assert cron(day="last sun", month="mar", hour=1)["schedule"] == "0 1 * 3 0L"
    assert cron(second="*/10")["schedule"] == "*/10 * * * * *"
    assert cron(month="jan-mar", day=1, hour=0)["schedule"] == "0 0 1 1-3 *"
    assert convert(CronTrigger(hour=1, minute=30, timezone="Europe/London"), "cronwatch: job") == {"schedule": "30 1 * * *", "timezone": "Europe/London"}
    with pytest.raises(ScheduleError, match="^cronwatch: job sets the week field \\(1\\), which CronWatch cannot read$"):
        cron(week=1)
    with pytest.raises(ScheduleError, match="sets the year field"):
        cron(year=2027)
    with pytest.raises(ScheduleError, match="mixes a weekday of the month"):
        cron(day="1st fri,15")


def test_intervals_dates_and_other_triggers() -> None:
    assert convert(IntervalTrigger(minutes=90, timezone=UTC)) == {"schedule": "every 1h30m"}
    assert convert(IntervalTrigger(seconds=5, timezone=UTC)) == {"schedule": "every 5s"}
    assert convert(DateTrigger(datetime(2030, 1, 1, tzinfo=timezone.utc))) is None
    with pytest.raises(ScheduleError, match="^cronwatch: this job has a OrTrigger, which CronWatch cannot read$"):
        convert(OrTrigger([CronTrigger(hour=1, timezone=UTC), CronTrigger(hour=2, timezone=UTC)]))


def test_every_job_is_declared_with_its_trigger_and_later_changes_follow() -> None:
    errors = Errors()
    cw, _, _ = make(on_error=errors)
    scheduler = BackgroundScheduler(timezone=UTC)
    scheduler.add_job(nightly_report, "cron", hour=2, id="nightly-report")
    scheduler.add_job(broken, "interval", minutes=10)  # an id APScheduler makes: named after the function
    scheduler.add_job(nightly_report, "cron", hour=5, id="left-alone")
    scheduler.add_job(nightly_report, OrTrigger([CronTrigger(hour=1, timezone=UTC), CronTrigger(hour=2, timezone=UTC)]), id="combined")
    watched = watch(scheduler, client=cw, grace="20m", exclude=["left-alone"], jobs={"nightly-report": {"timeout": "2h"}})
    try:
        watched.flush()
        definitions = {d.name: d.to_dict() for d in cw.defined_jobs()}
        assert definitions == {
            "nightly-report": {"grace": "20m", "schedule": "0 2 * * *", "timezone": "UTC", "timeout": "2h", "name": "nightly-report"},
            "broken": {"grace": "20m", "schedule": "every 10m", "name": "broken"},
            "combined": {"grace": "20m", "name": "combined"},
        }
        assert errors.wheres == ['declaring APScheduler job "combined"']
        scheduler.start(paused=True)
        scheduler.reschedule_job("nightly-report", trigger="cron", hour=3)
        watched.flush()
        assert {d.name: d.schedule for d in cw.defined_jobs()}["nightly-report"] == "0 3 * * *"
        scheduler.remove_job("nightly-report")
        watched.flush()
        gone = {d.name: d.to_dict() for d in cw.defined_jobs()}["nightly-report"]
        assert "schedule" not in gone and gone["timeout"] == "2h", "a removed job keeps its options, not its schedule"
    finally:
        scheduler.shutdown(wait=False)
        watched.close()


def test_runs_are_recorded_from_a_real_background_scheduler() -> None:
    cw, _, alerts = make()
    scheduler = BackgroundScheduler(timezone=UTC)
    watched = watch(scheduler, client=cw)
    done = threading.Event()

    def ok() -> str:
        return "sent 40 emails"

    def fail() -> None:
        try:
            raise ValueError("bad row")
        finally:
            done.set()

    scheduler.add_job(ok, "date", run_date=datetime.now(timezone.utc) + timedelta(milliseconds=50), id="ok")
    scheduler.add_job(fail, "date", run_date=datetime.now(timezone.utc) + timedelta(milliseconds=100), id="fail")
    scheduler.start()
    try:
        assert done.wait(10)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and (len(cw.runs("fail")) + len(cw.runs("ok")) < 2 or any(r.status == "running" for r in cw.runs("fail") + cw.runs("ok"))):
            watched.flush()
            time.sleep(0.05)
    finally:
        scheduler.shutdown()
        watched.close()
    [ok_run] = cw.runs("ok")
    assert (ok_run.status, ok_run.output, ok_run.trigger) == ("ok", "sent 40 emails", "apscheduler")
    [failed] = cw.runs("fail")
    assert failed.status == "failed"
    assert failed.error.startswith("ValueError: bad row\n    at fail (")
    assert alerts.types() == ["failed"]
    assert cronwatch.current() is None


def test_an_asyncio_scheduler_is_recorded_without_the_store_on_its_loop() -> None:
    cw, _, _ = make()
    seen: list[bool] = []
    loop_thread: list[int] = []
    original = cw.store.insert_run

    def insert_run(run: Any) -> None:
        seen.append(bool(loop_thread) and threading.get_ident() == loop_thread[0])
        original(run)

    cw.store.insert_run = insert_run  # type: ignore[method-assign]

    async def job() -> str:
        await asyncio.sleep(0)
        return "async job"

    async def main() -> None:
        loop_thread.append(threading.get_ident())
        scheduler = AsyncIOScheduler(timezone=UTC)
        watched = watch(scheduler, client=cw)
        scheduler.add_job(job, "date", run_date=datetime.now(timezone.utc) + timedelta(milliseconds=20), id="async-job")
        scheduler.start()
        for _ in range(200):
            await asyncio.sleep(0.02)
            if any(r.status == "ok" for r in cw.runs("async-job")):
                break
        scheduler.shutdown(wait=False)
        await asyncio.to_thread(watched.close)

    asyncio.run(main())
    assert [r.output for r in cw.runs("async-job")] == ["async job"]
    assert seen and not any(seen), "the store is never used on the event loop"


def fixed_scheduler(cw: Any) -> tuple[BackgroundScheduler, Any]:
    scheduler = BackgroundScheduler(timezone=UTC)
    scheduler.add_job(nightly_report, "cron", hour=2, id="nightly-report")
    return scheduler, watch(scheduler, client=cw)


def test_a_run_that_ends_before_its_submission_is_heard_of_is_recorded_once() -> None:
    cw, _, _ = make()
    scheduler, watched = fixed_scheduler(cw)
    due = datetime(2026, 1, 6, 2, tzinfo=timezone.utc)
    try:
        scheduler._dispatch_event(JobExecutionEvent(EVENT_JOB_EXECUTED, "nightly-report", "default", due, retval="fast"))
        scheduler._dispatch_event(JobSubmissionEvent(EVENT_JOB_SUBMITTED, "nightly-report", "default", [due]))
        watched.flush()
        assert [(r.status, r.output) for r in cw.runs("nightly-report")] == [("ok", "fast")]
        assert cw.store.running_runs() == []
    finally:
        watched.close()


def test_caught_up_runs_misses_and_errors() -> None:
    cw, _, alerts = make()
    scheduler, watched = fixed_scheduler(cw)
    first = datetime(2026, 1, 6, 2, tzinfo=timezone.utc)
    second = first + timedelta(days=1)
    third = second + timedelta(days=1)
    try:
        scheduler._dispatch_event(JobSubmissionEvent(EVENT_JOB_SUBMITTED, "nightly-report", "default", [first, second, third]))
        watched.flush()
        assert [r.status for r in cw.store.running_runs()] == ["running"], "one run under way"
        scheduler._dispatch_event(JobExecutionEvent(EVENT_JOB_EXECUTED, "nightly-report", "default", first, retval="one"))
        scheduler._dispatch_event(JobExecutionEvent(EVENT_JOB_ERROR, "nightly-report", "default", second, exception=RuntimeError("two")))
        scheduler._dispatch_event(JobExecutionEvent(EVENT_JOB_MISSED, "nightly-report", "default", third))
        watched.flush()
        runs = cw.runs("nightly-report")
        assert [(r.status, r.output or r.error.split("\n")[0]) for r in reversed(runs)] == [("ok", "one"), ("failed", "RuntimeError: two")]
        later = first + timedelta(days=5)
        scheduler._dispatch_event(JobSubmissionEvent(EVENT_JOB_SUBMITTED, "nightly-report", "default", [later]))
        scheduler._dispatch_event(JobExecutionEvent(EVENT_JOB_MISSED, "nightly-report", "default", later))
        watched.flush()
        skipped = cw.runs("nightly-report")[0]
        assert skipped.status == "failed"
        assert skipped.error.startswith("APScheduler skipped the run: it could not start within misfire_grace_time of 2026-01-11T02:00:00+00:00")
        assert alerts.types() == ["failed"]
    finally:
        watched.close()


def test_a_job_without_a_usable_name_is_reported_and_left_alone() -> None:
    errors = Errors()
    cw, _, _ = make(on_error=errors)
    scheduler = BackgroundScheduler(timezone=UTC)
    scheduler.add_job(lambda: None, "interval", minutes=5)
    watched = watch(scheduler, client=cw)
    try:
        watched.flush()
        assert cw.defined_jobs() == []
        assert "has no id or name CronWatch can use as a job name" in errors.messages[0]
        with pytest.raises(TypeError, match="takes schedule from each job's trigger"):
            watch(scheduler, client=cw, schedule="* * * * *")
    finally:
        watched.close()
