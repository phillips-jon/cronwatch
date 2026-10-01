"""cronwatch.celery: tasks recorded through Celery's signals, eagerly (apply,
task_always_eager), by a real worker in this process (the in-memory broker,
the solo and threads pools), and by a real prefork worker with Redis when
CRONWATCH_TEST_REDIS is set; beat's schedules read and checked; the check task.
django-celery-beat's table is read in a process of its own."""

from __future__ import annotations

import os
import signal
import subprocess
import sys
import time
import uuid
from collections.abc import Iterator
from typing import Any

import pytest

celery = pytest.importorskip("celery")

from celery import Celery  # noqa: E402
from celery.exceptions import Ignore, Reject  # noqa: E402
from celery.schedules import crontab  # noqa: E402

import cronwatch  # noqa: E402
import cronwatch.celery as cwcelery  # noqa: E402
from cronwatch.celery import CHECK_TASK, ScheduleError, _BeatEntry, _convert, _cron_text, cronwatch_task, install  # noqa: E402
from cronwatch.stores import SqliteStore  # noqa: E402

from helpers import HOUR, Errors, make, run_python  # noqa: E402

REDIS = os.environ.get("CRONWATCH_TEST_REDIS") or None
NO_REDIS = "set CRONWATCH_TEST_REDIS to a Redis URL to run a prefork worker"


class Fortnightly(celery.schedules.BaseSchedule):
    """A schedule of the app's own making, which CronWatch cannot read (as it cannot read a solar one)."""

    def is_due(self, last_run_at: Any) -> Any:
        return celery.schedules.schedstate(False, 60)


def new_app(**conf: Any) -> Celery:
    app = Celery(f"t{uuid.uuid4().hex[:8]}", broker="memory://", backend="cache+memory://", set_as_current=False)
    app.conf.update({"task_always_eager": True, "timezone": "UTC", **conf})
    return app


@pytest.fixture(autouse=True)
def forget_decorations() -> Iterator[None]:
    yield
    with cwcelery._pending_lock:
        cwcelery._pending.clear()


# ---------------------------------------------------------------- schedules


def test_crontabs_become_the_cron_expression_croner_reads_in_the_apps_zone() -> None:
    app = new_app(timezone="Europe/London")

    def entry(schedule: Any) -> _BeatEntry:
        return _BeatEntry(key="k", label='beat_schedule entry "k"', task="t", schedule=celery.schedules.maybe_schedule(schedule, app=app))

    assert _cron_text(crontab()) == "* * * * *"
    assert _cron_text(crontab(minute="*/15")) == "*/15 * * * *"
    assert _cron_text(crontab(minute=0, hour="9-17", day_of_week="mon-fri")) == "0 9-17 * * 1-5"
    assert _cron_text(crontab(minute=0, hour=4, day_of_month="1-7", day_of_week="sun")) == "0 4 1-7 * +0", "Celery wants both days"
    assert _cron_text(crontab(minute="0,20,40", hour="1,2", month_of_year="jan,jul")) == "*/20 1,2 * 1,7 *"
    assert _convert(entry(crontab(hour=2, minute=0)), app) == {"schedule": "0 2 * * *", "timezone": "Europe/London"}
    assert _convert(entry(90), app) == {"schedule": "every 1m30s"}
    assert _convert(entry(3600.5), app) == {"schedule": "every 1h500ms"}
    with pytest.raises(ScheduleError, match='^cronwatch: beat_schedule entry "k" is a Fortnightly schedule, which CronWatch cannot read$'):
        _convert(entry(Fortnightly()), app)
    with pytest.raises(ScheduleError, match="never fires"):
        _convert(entry(crontab(minute=0, hour=0, day_of_month=31, month_of_year=2)), app)
    with pytest.raises(ScheduleError, match="one second or more"):
        _convert(entry(0.5), app)
    utc = new_app()
    utc.conf.timezone = None
    assert _convert(_BeatEntry("k", "k", "t", celery.schedules.maybe_schedule(crontab(minute=5), app=utc)), utc) == {"schedule": "5 * * * *", "timezone": "UTC"}


def test_install_declares_every_task_beat_schedules_before_it_runs() -> None:
    app = new_app()
    app.conf.beat_schedule = {
        "nightly-report": {"task": "reports.nightly", "schedule": crontab(hour=2, minute=0)},
        "sync": {"task": "reports.sync", "schedule": 300},
        "cronwatch-check": {"task": CHECK_TASK, "schedule": 300},
        "cleanup": {"task": "celery.backend_cleanup", "schedule": crontab(hour=4, minute=0)},
    }
    cw, clock, alerts = make()
    watch = install(app, client=cw, grace="15m")
    handles = watch.declare()
    assert sorted(h.name for h in handles) == ["reports.nightly", "reports.sync"], "not the check, nor Celery's own"
    nightly = cw.defined_jobs()[0] if cw.defined_jobs()[0].name == "reports.nightly" else cw.defined_jobs()[1]
    assert nightly.to_dict() == {"grace": "15m", "schedule": "0 2 * * *", "timezone": "UTC", "name": "reports.nightly"}
    assert app.tasks[CHECK_TASK].apply().get() == "cronwatch: checked 2 jobs, sent 0 alerts"
    clock.set(clock.now() + 17 * HOUR)  # past 02:15 the next day
    result = app.tasks[CHECK_TASK].apply().get()
    assert result == "cronwatch: checked 2 jobs, sent 2 alerts", "missed, though neither ever ran here"
    assert sorted(alerts.types()) == ["missed", "missed"]


def test_a_task_forgotten_while_beat_schedules_it_is_declared_again_at_the_next_declare() -> None:
    app = new_app()
    app.conf.beat_schedule = {"nightly-report": {"task": "reports.nightly", "schedule": crontab(hour=2, minute=0)}}
    cw, _, _ = make()
    watch = install(app, client=cw)
    watch.declare()
    cw.forget("reports.nightly")
    assert cw.defined_jobs() == []
    assert [h.name for h in watch.declare()] == ["reports.nightly"]
    assert [d.schedule for d in cw.defined_jobs()] == ["0 2 * * *"]
    assert [j.name for j in cw.jobs()] == ["reports.nightly"], "back on the board before it next runs"


def test_a_schedule_that_cannot_be_read_is_reported_once_and_the_task_is_still_watched() -> None:
    app = new_app()
    app.conf.beat_schedule = {
        "odd": {"task": "t.odd", "schedule": Fortnightly()},
        "twice-a": {"task": "t.twice", "schedule": crontab(minute=0, hour=1)},
        "twice-b": {"task": "t.twice", "schedule": crontab(minute=0, hour=13)},
    }
    errors = Errors()
    cw, _, _ = make(on_error=errors)
    watch = install(app, client=cw)
    with pytest.raises(ScheduleError, match="Fortnightly"):
        watch.declare()
    names = sorted(h.name for h in watch.declare(strict=False))
    assert names == ["t.odd", "t.twice"]
    assert all(d.schedule is None for d in cw.defined_jobs())
    watch.declare(strict=False)
    assert errors.wheres == ['declaring beat_schedule entry "odd"', "declaring task t.twice"], "once each"
    assert "is scheduled 2 times (beat_schedule entry \"twice-a\", beat_schedule entry \"twice-b\")" in errors.messages[1]
    exclude = install(app, client=cw, exclude=["twice-b", "t.odd"])
    assert {h.name: h.definition.schedule for h in exclude.declare()} == {"t.twice": "0 1 * * *"}


# ---------------------------------------------------------------- runs, eagerly


def test_a_run_is_recorded_with_the_tasks_id_its_output_and_the_context() -> None:
    app = new_app()
    app.conf.beat_schedule = {"nightly": {"task": "e.nightly", "schedule": crontab(hour=2, minute=0)}}
    cw, _, alerts = make()
    install(app, client=cw)

    @app.task(shared=False, name="e.nightly")
    def nightly(rows: int) -> str:
        context = cronwatch.current()
        assert context is not None
        context.log("Report written:", rows)
        context.metric("rows", rows)
        return "done"

    @app.task(shared=False, name="e.unwatched")
    def unwatched() -> str:
        assert cronwatch.current() is None
        return "free"

    result = nightly.apply(args=(42,), task_id="abc-123")
    assert result.get() == "done"
    [run] = cw.runs("e.nightly")
    assert (run.status, run.trigger, run.output, run.metrics) == ("ok", "celery", "Report written: 42", {"rows": 42})
    assert run.id.startswith("abc-123:")
    assert cronwatch.current() is None
    assert unwatched.delay().get() == "free"
    assert [j.name for j in cw.jobs()] == ["e.nightly"]
    assert alerts.types() == []


def test_a_failure_is_recorded_and_raised_on_to_celery_as_before() -> None:
    app = new_app()
    cw, _, alerts = make()
    install(app, client=cw, tasks={"e.boom": {}})

    @app.task(shared=False, name="e.boom")
    def boom() -> None:
        raise RuntimeError("db down")

    result = boom.apply()
    assert result.state == "FAILURE"
    assert isinstance(result.result, RuntimeError)
    with pytest.raises(RuntimeError, match="db down"):
        boom.apply(throw=True)  # task_eager_propagates: past Celery's own handling
    runs = cw.runs("e.boom")
    assert [r.status for r in runs] == ["failed", "failed"]
    assert all(r.error.startswith("RuntimeError: db down\n    at boom (") for r in runs)
    assert alerts.types() == ["failed"], "one alert for failures in a row"


def test_retries_are_runs_of_their_own_and_open_one_alert_as_the_gem_has_sidekiqs() -> None:
    app = new_app()
    cw, _, alerts = make()
    install(app, client=cw, tasks={"e.flaky": {}})
    attempts: list[int] = []

    @app.task(shared=False, name="e.flaky", bind=True, autoretry_for=(ValueError,), max_retries=3, retry_backoff=False, default_retry_delay=0)
    def flaky(self: Any) -> str:
        attempts.append(self.request.retries)
        if self.request.retries < 2:
            raise ValueError(f"attempt {self.request.retries}")
        return "third time"

    assert flaky.apply().get() == "third time"
    assert attempts == [0, 1, 2]
    runs = cw.runs("e.flaky")
    assert [(r.status, (r.error or "").split("\n")[0]) for r in reversed(runs)] == [
        ("failed", "ValueError: attempt 0"),
        ("failed", "ValueError: attempt 1"),
        ("ok", ""),
    ]
    assert len({r.id.split(":")[0] for r in runs}) == 1, "one task id, a run per attempt"
    assert alerts.types() == ["failed", "recovered"]

    waiting, _, waiting_alerts = make()
    install(app, client=waiting, tasks={"e.flaky": {"failures_before_alert": 3}})
    attempts.clear()
    flaky.apply()
    assert waiting_alerts.types() == [], "two failed attempts, then a success: under failures_before_alert=3"


def test_ignore_is_an_ok_run_and_reject_a_failed_one() -> None:
    app = new_app()
    cw, _, _ = make()
    install(app, client=cw, tasks={"e.ignored": {}, "e.rejected": {}})

    @app.task(shared=False, name="e.ignored")
    def ignored() -> None:
        raise Ignore()

    @app.task(shared=False, name="e.rejected")
    def rejected() -> None:
        raise Reject("bad message", requeue=False)

    ignored.apply()
    rejected.apply()
    assert cw.runs("e.ignored")[0].status == "ok"
    assert cw.runs("e.rejected")[0].status == "failed"
    assert cw.runs("e.rejected")[0].error.startswith("Reject: ")


def test_the_decorator_gives_a_task_its_options_above_or_below_the_task_decorator() -> None:
    app = new_app()
    app.conf.beat_schedule = {"n": {"task": "d.below", "schedule": crontab(hour=3, minute=0)}}
    cw, _, _ = make()
    install(app, client=cw)

    @app.task(shared=False, name="d.below")
    @cronwatch_task(name="nightly-report", timeout="2h", expect="written")
    def below() -> str:
        return "Report written"

    @cronwatch_task(schedule="*/5 * * * *", timezone="UTC")
    @app.task(shared=False, name="d.above")
    def above() -> None:
        pass

    below.apply()
    above.apply()
    by_name = {d.name: d.to_dict() for d in cw.defined_jobs()}
    assert by_name["nightly-report"] == {"schedule": "0 3 * * *", "timezone": "UTC", "timeout": "2h", "expect": "written", "name": "nightly-report"}
    assert by_name["d.above"]["schedule"] == "*/5 * * * *"
    assert cw.runs("nightly-report")[0].status == "ok"
    with pytest.raises(TypeError, match="unknown option shedule"):
        cronwatch_task(shedule="x")
    with pytest.raises(TypeError, match="takes schedule from beat"):
        install(app, client=cw, schedule="* * * * *")


def test_task_always_eager_delay_is_recorded_and_the_check_task_is_never_a_job() -> None:
    app = new_app()
    cw, _, _ = make()
    install(app, client=cw, tasks={"e.plain": {}})

    @app.task(shared=False, name="e.plain")
    def plain() -> int:
        return 7

    assert plain.delay().get() == 7
    app.tasks[CHECK_TASK].delay()
    assert [j.name for j in cw.jobs()] == ["e.plain"]


def test_the_default_client_is_the_process_client(monkeypatch: pytest.MonkeyPatch) -> None:
    # Outside a Django project (test_django.py makes one in this process).
    monkeypatch.delitem(sys.modules, "cronwatch.django", raising=False)
    app = new_app()
    made = cronwatch.configure(alerts=[], cron_secret=None)
    install(app, tasks={"e.default": {}})

    @app.task(shared=False, name="e.default")
    def default() -> None:
        pass

    default.apply()
    assert [r.job for r in made.runs("e.default")] == ["e.default"]


def test_a_django_client_that_fails_to_load_is_not_replaced_by_one_in_memory(monkeypatch: pytest.MonkeyPatch) -> None:
    # A typo in settings.CRONWATCH (a STORE path, an unknown key) must be
    # heard, not quietly swapped for a client that records into worker memory.
    from types import SimpleNamespace

    def broken() -> Any:
        raise ImportError("CRONWATCH['STORE']: no module named 'myapp.monitoring'")

    monkeypatch.setitem(sys.modules, "cronwatch.django", SimpleNamespace(client=broken))
    monkeypatch.setattr("django.conf.settings", SimpleNamespace(configured=True))
    fallback = cronwatch.configure(alerts=[], cron_secret=None)
    with pytest.raises(ImportError, match="myapp.monitoring"):
        cwcelery._default_client()
    app = new_app()
    result = app.tasks[CHECK_TASK].apply()
    assert result.failed()
    assert "myapp.monitoring" in str(result.result)
    # A watched task still runs: Celery logs the error its signal handler raised.
    install(app, tasks={"e.broken": {}})

    @app.task(shared=False, name="e.broken")
    def work() -> int:
        return 3

    assert work.apply().get() == 3
    # Only Django settings that are not configured at all leave the process's client.
    monkeypatch.setattr("django.conf.settings", SimpleNamespace(configured=False))
    assert cwcelery._default_client() is fallback


# ---------------------------------------------------------------- a real worker, in this process


@pytest.mark.parametrize("pool", ["solo", "threads"])
def test_a_worker_in_this_process_records_runs_through_the_same_signals(pool: str) -> None:
    from celery.contrib.testing.worker import start_worker

    app = new_app(task_always_eager=False)
    cw, _, alerts = make()
    install(app, client=cw, tasks={"w.ok": {}, "w.bad": {}})

    @app.task(shared=False, name="w.ok")
    def ok(n: int) -> str:
        context = cronwatch.current()
        assert context is not None
        context.log("worked", n)
        return "fine"

    @app.task(shared=False, name="w.bad", bind=True, max_retries=1, default_retry_delay=0)
    def bad(self: Any) -> None:
        raise self.retry(exc=KeyError("missing"))

    with start_worker(app, pool=pool, concurrency=2, perform_ping_check=False):
        assert ok.delay(1).get(timeout=20) == "fine"
        assert ok.delay(2).get(timeout=20) == "fine"
        with pytest.raises(KeyError):
            bad.delay().get(timeout=20)
    outputs = sorted(r.output for r in cw.runs("w.ok"))
    assert outputs == ["worked 1", "worked 2"]
    bad_runs = cw.runs("w.bad")
    assert [r.status for r in bad_runs] == ["failed", "failed"], "the retried attempt and the last one"
    assert all(r.error.startswith("KeyError: 'missing'") for r in bad_runs)
    assert alerts.types() == ["failed"]


# ---------------------------------------------------------------- a prefork worker with Redis


@pytest.mark.skipif(REDIS is None, reason=NO_REDIS)
def test_a_prefork_worker_records_from_its_children_and_fails_runs_whose_child_is_lost(tmp_path: Any) -> None:
    here = os.path.dirname(os.path.abspath(__file__))
    db = str(tmp_path / "cronwatch.db")
    queue = f"cwtest-{uuid.uuid4().hex[:8]}"
    env = {**os.environ, "CW_BROKER": REDIS or "", "CW_DB": db, "CW_QUEUE": queue, "PYTHONPATH": here}
    if sys.platform == "darwin":
        # macOS children do not inherit the worker's trace setup; Celery's own switch sets it up in each.
        env["FORKED_BY_MULTIPROCESSING"] = "1"
    worker = subprocess.Popen(
        [sys.executable, "-m", "celery", "-A", "celery_app", "worker", "--pool=prefork", "--concurrency=2", "--loglevel=WARNING", "-Q", queue],
        cwd=here,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    sys.path.insert(0, here)
    saved = {k: os.environ.get(k) for k in ("CW_BROKER", "CW_DB", "CW_QUEUE")}
    os.environ.update({"CW_BROKER": REDIS or "", "CW_DB": db, "CW_QUEUE": queue})
    try:
        import celery_app

        reader = cronwatch.Cronwatch(store=SqliteStore(db), alerts=[], cron_secret=None)

        def runs_of(name: str, status: str, deadline: float = 30) -> list[Any]:
            end = time.monotonic() + deadline
            while time.monotonic() < end:
                found = [r for r in reader.runs(name) if r.status == status]
                if found:
                    return found
                time.sleep(0.2)
            raise AssertionError(f"no {status} run of {name}; worker said:\n{worker.stdout.read1(65536).decode() if worker.stdout else ''}")

        assert celery_app.ok.delay().get(timeout=60) == "done"
        [ok] = runs_of("cwtest.ok", "ok")
        assert ok.output.startswith("child ")
        assert int(ok.output.split()[1]) != worker.pid, "run in a child process"

        slow = celery_app.slow.delay()
        [timed_out] = runs_of("cwtest.slow", "failed")
        assert timed_out.id.startswith(f"{slow.id}:")
        assert timed_out.error.startswith("TimeLimitExceeded"), timed_out.error

        died = celery_app.die.delay()
        [lost] = runs_of("cwtest.die", "failed")
        assert lost.id.startswith(f"{died.id}:")
        assert lost.error.startswith("WorkerLostError"), lost.error
    finally:
        for key, value in saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        sys.path.remove(here)
        worker.send_signal(signal.SIGTERM)
        try:
            worker.wait(timeout=30)
        except subprocess.TimeoutExpired:
            worker.kill()


# ---------------------------------------------------------------- django-celery-beat


def test_django_celery_beats_periodic_tasks_are_read_and_win_over_beat_schedule(tmp_path: Any) -> None:
    pytest.importorskip("django_celery_beat")
    (tmp_path / "beat_settings.py").write_text(
        'SECRET_KEY = "cronwatch-tests-only"\n'
        'INSTALLED_APPS = ["django_celery_beat"]\n'
        'DATABASES = {"default": {"ENGINE": "django.db.backends.sqlite3", "NAME": ":memory:"}}\n'
        'USE_TZ = True\n'
    )
    script = (
        "import django, json\n"
        "django.setup()\n"
        "from django.core.management import call_command\n"
        'call_command("migrate", verbosity=0)\n'
        "from django_celery_beat.models import CrontabSchedule, IntervalSchedule, PeriodicTask, ClockedSchedule\n"
        "from zoneinfo import ZoneInfo\n"
        "from datetime import datetime, timezone\n"
        'night = CrontabSchedule.objects.create(minute="30", hour="4", day_of_week="*", day_of_month="*", month_of_year="*", timezone=ZoneInfo("America/New_York"))\n'
        'PeriodicTask.objects.create(name="nightly", task="proj.nightly", crontab=night, description="The nightly report")\n'
        'often = IntervalSchedule.objects.create(every=10, period="minutes")\n'
        'PeriodicTask.objects.create(name="often", task="proj.often", interval=often)\n'
        'PeriodicTask.objects.create(name="off", task="proj.off", interval=often, enabled=False)\n'
        "once = ClockedSchedule.objects.create(clocked_time=datetime(2030, 1, 1, tzinfo=timezone.utc))\n"
        'PeriodicTask.objects.create(name="once", task="proj.once", clocked=once, one_off=True)\n'
        "from celery import Celery\n"
        "import cronwatch, cronwatch.celery\n"
        'app = Celery("proj", set_as_current=False)\n'
        'app.conf.beat_schedule = {"nightly": {"task": "proj.nightly", "schedule": 60}, "conf-only": {"task": "proj.conf", "schedule": 120}}\n'
        "cw = cronwatch.Cronwatch(alerts=[], cron_secret=None)\n"
        "watch = cronwatch.celery.install(app, client=cw)\n"
        "print(json.dumps({h.name: h.definition.to_dict() for h in watch.declare()}, sort_keys=True))\n"
    )
    done = run_python(script, tmp_path, DJANGO_SETTINGS_MODULE="beat_settings")
    import json

    assert json.loads(done.stdout) == {
        "proj.conf": {"name": "proj.conf", "schedule": "every 2m"},
        "proj.nightly": {"description": "The nightly report", "name": "proj.nightly", "schedule": "30 4 * * *", "timezone": "America/New_York"},
        "proj.often": {"name": "proj.often", "schedule": "every 10m"},
    }
