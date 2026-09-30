"""The pg_cron source against cron.job and cron.job_run_details held in
memory (as packages/sdk/test/pgcron.test.ts and the gem's pg_cron_test.rb),
and, when CRONWATCH_TEST_PGCRON is the URL of a Postgres with pg_cron,
against the real thing through psycopg."""

from __future__ import annotations

import datetime as dt
import os
import time
import urllib.parse
from dataclasses import dataclass
from typing import Any

import pytest

from cronwatch import Cronwatch
from cronwatch._js import date_utc
from cronwatch.sources import pgcron
from cronwatch.sources.pgcron import PgCron
from cronwatch.stores import MemoryStore

from helpers import HOUR, MIN, NO_PGCRON, PGCRON, T0, Capture, Clock

DAY = 24 * HOUR


def at(ms: int) -> dt.datetime:
    return dt.datetime.fromtimestamp(ms / 1000, dt.timezone.utc)


@dataclass
class Detail:
    runid: int
    jobid: int
    status: str
    return_message: str | None
    start_time: dt.datetime | None
    end_time: dt.datetime | None


class FakeCron:
    """cron.job and cron.job_run_details in memory, answering the reader's queries."""

    def __init__(self) -> None:
        self.jobs: list[dict[str, Any]] = []
        self.details: list[Detail] = []
        self.runid = 0
        self.queries: list[str] = []
        self.settings: dict[str, str] = {"cron.timezone": "GMT", "cron.log_run": "on"}

    def job(self, jobid: int, jobname: str | None, schedule: str, active: bool = True) -> None:
        self.jobs.append({"jobid": jobid, "jobname": jobname, "schedule": schedule, "database": "postgres", "username": "postgres", "active": active})

    def add(self, jobid: int, status: str, start: int | None, finish: int | None, message: str | None = None) -> Detail:
        self.runid += 1
        d = Detail(self.runid, jobid, status, message, None if start is None else at(start), None if finish is None else at(finish))
        self.details.append(d)
        return d

    def query(self, text: str, values: list[Any]) -> list[dict[str, Any]]:
        self.queries.append(text)
        if "pg_settings" in text:
            value = self.settings.get(values[0])
            return [] if value is None else [{"setting": value}]
        if "FROM cron.job ORDER BY" in text:
            return [{**j, "jobid": str(j["jobid"])} for j in self.jobs]
        if "ORDER BY d.runid DESC" in text:
            return self._out(sorted((d for d in self.details if d.jobid == values[0]), key=lambda d: -d.runid)[:20])
        if "unnest" in text:
            ids, afters, still_open = values
            after = dict(zip(ids, afters, strict=True))
            opened = {int(r) for r in still_open}
            return self._out(sorted((d for d in self.details if (d.jobid in after and d.runid > after[d.jobid]) or d.runid in opened), key=lambda d: d.runid)[:500])
        raise AssertionError(f"unexpected query {text}")

    @staticmethod
    def _out(rows: list[Detail]) -> list[dict[str, Any]]:
        return [
            {"runid": str(d.runid), "jobid": str(d.jobid), "status": d.status, "return_message": d.return_message, "start_time": d.start_time, "end_time": d.end_time}
            for d in rows
        ]


def client(cron: Any, clock: Clock | None = None, store: Any = None, errors: list[str] | None = None, capture: Capture | None = None, **options: Any) -> Cronwatch:
    return Cronwatch(
        store=store or MemoryStore(),
        alerts=[capture] if capture is not None else [],
        now=(clock or Clock()).now,
        cron_secret=None,
        on_error=(lambda e, _where: errors.append(str(e))) if errors is not None else (lambda e, _where: None),
        sources=[PgCron(cron, **options)],
    )


def job_named(result: Any, name: str) -> Any:
    return next(j for j in result.jobs if j.name == name)


def test_schedules_and_names() -> None:
    assert pgcron.schedule("30 seconds") == "every 30s"
    assert pgcron.schedule("1 second") == "every 1s"
    assert pgcron.schedule("0 0 $ * *") == "0 0 L * *"
    assert pgcron.schedule(" */5  * * * * ") == "*/5 * * * *"
    assert pgcron.schedule("@reboot") is None
    assert pgcron.job_name(pgcron.Job(jobid=7, jobname="nightly vacuum")) == "nightly-vacuum"
    assert pgcron.job_name(pgcron.Job(jobid=7, jobname=None)) == "pg_cron:7"
    assert pgcron.job_name(pgcron.Job(jobid=7, jobname="  ")) == "pg_cron:7"


def test_pg_cron_ignores_fields_past_the_fifth_and_so_does_the_reader() -> None:
    assert pgcron.schedule("0 5 * * * *") == "0 5 * * *"
    assert pgcron.schedule("* * * * * *") == "* * * * *"
    assert pgcron.schedule("0 0 $ * * extra") == "0 0 L * *"
    assert pgcron.schedule("@hourly") == "@hourly"


def test_rows_become_runs() -> None:
    row = {"runid": "9", "jobid": "1", "status": "failed", "return_message": "  ERROR:  boom\n", "start_time": at(T0), "end_time": "2026-01-05 09:30:02.5+00"}
    run = pgcron.run(row, "vacuum", "pgcron:")
    assert [run.id, run.status, run.started_at, run.finished_at, run.duration_ms, run.error, run.output, run.trigger] == [
        "pgcron:9", "failed", T0, T0 + 2500, 2500, "ERROR:  boom", None, "pg_cron",
    ]  # fmt: skip
    assert pgcron.run({**row, "return_message": " "}, "vacuum", "pgcron:").error == "pg_cron reported the run as failed"
    going = pgcron.run({**row, "status": "running", "end_time": None}, "vacuum", "pgcron:")
    assert [going.status, going.finished_at, going.duration_ms, going.error] == ["running", None, None, None]
    assert pgcron.run({**row, "status": "starting", "start_time": None, "end_time": None}, "vacuum", "pgcron:") is None, "not started yet"
    # A run a server restart cut off: failed, no start_time; it starts at its end_time, else at the fallback.
    cut = pgcron.run({**row, "start_time": None, "return_message": "server restarted"}, "vacuum", "pgcron:", T0 - HOUR)
    assert [cut.status, cut.started_at, cut.finished_at, cut.duration_ms, cut.error] == ["failed", T0 + 2500, T0 + 2500, 0, "server restarted"]
    timeless = pgcron.run({**row, "start_time": None, "end_time": None}, "vacuum", "pgcron:", T0 - HOUR)
    assert [timeless.started_at, timeless.finished_at, timeless.duration_ms] == [T0 - HOUR, T0 - HOUR, 0]
    naive = pgcron.run({**row, "start_time": dt.datetime(2026, 1, 5, 9, 30)}, "vacuum", "pgcron:")
    assert naive.started_at == T0, "a timestamp without a zone is UTC"


def test_jobs_are_declared_history_is_copied_quietly_and_imports_are_idempotent() -> None:
    clock = Clock()
    cron = FakeCron()
    cron.job(1, "nightly vacuum", "0 3 * * *")
    cron.job(2, None, "10 seconds")
    cron.job(3, "paused", "0 * * * *", False)
    cron.job(4, "other", "0 * * * *")
    three = date_utc(2026, 0, 5, 3)
    for i in range(24, 0, -1):
        cron.add(1, "succeeded", three - i * DAY, three - i * DAY + 5000, "VACUUM")
    cron.add(1, "failed", three, three + 2000, "ERROR:  deadlock detected\n")
    store = MemoryStore()
    capture = Capture()

    def fresh() -> Cronwatch:
        return client(cron, clock, store, capture=capture, jobs=lambda j: j.jobid != 4, prefix="db:")

    cw = fresh()
    first = cw.check()
    assert [j.name for j in first.jobs] == ["db:nightly-vacuum", "db:paused", "db:pg_cron:2"]
    vacuum = job_named(first, "db:nightly-vacuum")
    assert vacuum.definition.schedule == "0 3 * * *"
    assert vacuum.definition.timezone == "UTC"
    assert vacuum.definition.tags == ["pg_cron"]
    assert job_named(first, "db:pg_cron:2").definition.schedule == "every 10s"
    assert job_named(first, "db:paused").definition.schedule is None, "a paused job is not expected to run"
    runs = cw.runs("db:nightly-vacuum", 100)
    assert len(runs) == 20, "twenty newest runs copied on first sight"
    assert [runs[0].id, runs[0].status, runs[0].error, runs[0].duration_ms, runs[0].trigger] == ["pgcron:db:25", "failed", "ERROR:  deadlock detected", 2000, "pg_cron"]
    assert runs[1].output == "VACUUM"
    assert capture.types() == ["failed"], "only the newest finished run is judged; history does not alert"

    cw.check()
    cw = fresh()
    cw.check()
    assert len(cw.runs("db:nightly-vacuum", 100)) == 20, "a re-import, even after a restart, adds nothing"
    assert capture.types() == ["failed"]

    # A run not yet started holds the cursor; the run after it is copied now and it is copied once it starts.
    starting = cron.add(2, "starting", None, None)
    cron.add(2, "succeeded", T0 - 5000, T0 - 4000, "1 row")
    clock.advance(1000)
    cw.check()
    assert [r.id for r in cw.runs("db:pg_cron:2")] == ["pgcron:db:27"]
    starting.status = "running"
    starting.start_time = at(T0 - 3000)
    cw.check()
    assert cw.get_run("pgcron:db:26").status == "running"
    starting.status = "failed"
    starting.end_time = at(T0 - 1000)
    starting.return_message = "ERROR:  boom"
    clock.advance(1000)
    cw.check()
    finished = cw.get_run("pgcron:db:26")
    assert [finished.status, finished.duration_ms] == ["failed", 2000]
    assert capture.types() == ["failed", "failed"], "a run that was running and then failed is judged when it finishes"

    # The nightly job stops running: missed, from its schedule, with no run details at all.
    clock.set(date_utc(2026, 0, 6, 3, 11))
    cron.add(2, "succeeded", clock.now() - 2000, clock.now() - 1000, "1 row")
    later = cw.check()
    assert sorted(f"{a.type} {a.job}" for a in later.alerts) == ["missed db:nightly-vacuum", "recovered db:pg_cron:2"]
    assert cw.check().alerts == [], "each condition alerts once"

    # Unscheduled: its name keeps its history but loses its schedule, so it is never missed again,
    # and the missed alert it had open closes with a recovery that says so.
    cron.jobs.pop(0)
    clock.set(date_utc(2026, 0, 8, 3, 11))
    gone = cw.check()
    vacuum_now = job_named(gone, "db:nightly-vacuum")
    assert vacuum_now.definition.schedule is None
    assert "no longer watched" in vacuum_now.definition.description
    assert vacuum_now.open == ["failed"], "its failure stays open until a successful run"
    closed = [a for a in gone.alerts if a.job == "db:nightly-vacuum"]
    assert [a.type for a in closed] == ["recovered"]
    assert closed[0].title == "db:nightly-vacuum is no longer scheduled"
    assert closed[0].details == {"after": ["missed"], "reason": "unscheduled", "since": date_utc(2026, 0, 6, 3, 11)}
    assert not any(a.job == "db:nightly-vacuum" for a in cw.check().alerts), "once"
    assert len(cw.runs("db:nightly-vacuum", 100)) == 20, "its history is kept"


def test_job_options_apply_and_an_unreadable_schedule_is_reported() -> None:
    import re

    cron = FakeCron()
    cron.job(1, "odd", "not a schedule")
    errors: list[str] = []
    cw = client(cron, errors=errors, options={"grace": "1m", "expect": re.compile("rows?")})
    now = time.time_ns() // 1_000_000
    cron.add(1, "succeeded", now - 1000, now, "nothing")
    result = cw.check()
    assert result.jobs[0].definition.schedule is None
    assert result.jobs[0].definition.grace == "1m"
    assert "watching it without a schedule" in "\n".join(errors)
    run = cw.runs("odd")[0]
    assert run.status == "failed", "expect applies to imported output"
    assert "did not match" in run.error


def test_warnings_come_once() -> None:
    class Denied(FakeCron):
        def query(self, text: str, values: list[Any]) -> list[dict[str, Any]]:
            if "pg_settings" in text:
                raise RuntimeError("permission denied")
            return super().query(text, values)

    errors: list[str] = []
    cw = Cronwatch(alerts=[], cron_secret=None, on_error=lambda e, where: errors.append(f"{where}: {e}"), sources=[PgCron(Denied())])
    cw.check()
    cw.check()
    assert len(errors) == 2, errors
    assert "could not read cron.timezone; assuming UTC" in errors[0]
    assert "cron.job shows no jobs" in errors[1]


def test_adapters() -> None:
    with pytest.raises(TypeError):
        PgCron(object())
    queryable = FakeCron()
    assert pgcron.adapter(queryable) is queryable


def test_a_run_cut_off_by_a_restart_is_recorded_and_one_held_run_never_stops_the_others() -> None:
    clock = Clock()
    cron = FakeCron()
    cron.job(1, "fast", "30 seconds")
    cron.job(2, "other", "0 * * * *")
    errors: list[str] = []
    capture = Capture()
    cw = client(cron, clock, errors=errors, capture=capture)
    cron.add(1, "succeeded", T0 - 60_000, T0 - 59_000, "1 row")
    cw.check()
    # pg_cron restarts while a run is queued: it marks it failed, "server restarted", with no times at all.
    restarted = cron.add(1, "failed", None, None, "server restarted")
    # The fast job then runs far more than a page's worth, and the other job fails after all of them.
    for i in range(520):
        cron.add(1, "succeeded", T0 - 50_000 + i, T0 - 50_000 + i + 1, "1 row")
    failure = cron.add(2, "failed", T0 - 1000, T0 - 500, "ERROR:  disk full")
    queued = cron.add(1, "starting", None, None)
    clock.advance(1000)
    cw.check()
    cw.check()
    cut = cw.get_run(f"pgcron:{restarted.runid}")
    assert [cut.status, cut.error] == ["failed", "server restarted"]
    assert cut.started_at == T0 - 60_000, "placed at the job's newest run before it"
    assert cw.get_run(f"pgcron:{failure.runid}").status == "failed", "the other job's failure is not starved"
    assert any(a.type == "failed" and a.job == "other" for a in capture.alerts)
    assert cw.get_run(f"pgcron:{queued.runid}") is None, "a queued run is held"

    # Held only so long: then it is copied as running from when it was first seen, and a late start updates nothing but its end.
    clock.advance(11 * MIN)
    cw.check()
    waiting = cw.get_run(f"pgcron:{queued.runid}")
    assert [waiting.status, waiting.started_at] == ["running", T0 + 1000]
    queued.status = "succeeded"
    queued.start_time = at(clock.now() - 2000)
    queued.end_time = at(clock.now() - 1000)
    clock.advance(1000)
    cw.check()
    assert cw.get_run(f"pgcron:{queued.runid}").status == "ok"
    assert [e for e in errors if "cron." not in e and "row level" not in e] == []


def test_a_jobs_job_name_or_options_callback_that_fails_fails_only_its_job_reported_once() -> None:
    clock = Clock()
    cron = FakeCron()
    for jobid, name in [(1, "one"), (2, "two"), (3, "three"), (4, "four")]:
        cron.job(jobid, name, "0 * * * *")
    broken: set[str] = set()
    errors: list[str] = []

    def pick(j: Any) -> bool:
        if f"pick:{j.jobid}" in broken:
            raise RuntimeError("pick broke")
        return True

    def name_of(j: Any) -> Any:
        if f"raise:{j.jobid}" in broken:
            raise RuntimeError("name broke")
        if f"none:{j.jobid}" in broken:
            return None
        if f"number:{j.jobid}" in broken:
            return 7
        return f"j-{j.jobname}"

    def options_of(j: Any) -> dict[str, Any]:
        if f"options:{j.jobid}" in broken:
            raise RuntimeError("options broke")
        return {}

    cw = client(cron, clock, errors=errors, jobs=pick, job_name=name_of, options=options_of)

    def notices() -> list[str]:
        return [e for e in errors if "cron.timezone" not in e and "row level" not in e]

    def names() -> list[str]:
        return [j.name for j in cw.store.list_jobs()]

    # First sight, with job 1's name callback raising and job 2's giving None: only those two are skipped.
    broken |= {"raise:1", "none:2"}
    first = cron.add(3, "succeeded", T0 - 60_000, T0 - 59_000, "ok")
    cw.check()
    assert names() == ["j-four", "j-three"]
    assert cw.get_run(f"pgcron:{first.runid}").job == "j-three"
    assert notices() == [
        "pg_cron job 1: job_name raised RuntimeError: name broke; it keeps its last declaration until that works",
        "pg_cron job 2: job_name returned None, not a name; it keeps its last declaration until that works",
    ]

    # Once they work, both are declared; then every callback fails in turn for jobs already declared.
    broken.clear()
    cw.check()
    assert names() == ["j-four", "j-one", "j-three", "j-two"]
    broken |= {"pick:1", "number:2", "options:3", "raise:4"}
    errors.clear()
    later = [cron.add(1, "failed", T0 + 1000, T0 + 2000, "ERROR:  one"), cron.add(3, "succeeded", T0 + 1000, T0 + 2000, "ok")]
    clock.advance(5000)
    cw.check()
    cw.check()
    assert notices() == [
        "pg_cron job 1: the jobs callback raised RuntimeError: pick broke; it keeps its last declaration until that works",
        "pg_cron job 2: job_name returned int, not a name; it keeps its last declaration until that works",
        "pg_cron job 3: the options callback raised RuntimeError: options broke; it keeps its last declaration until that works",
        "pg_cron job 4: job_name raised RuntimeError: name broke; it keeps its last declaration until that works",
    ], "each reported once, over two syncs"
    # Each keeps its name and schedule, is not retired, and its runs are still copied.
    for stored in cw.store.list_jobs():
        assert stored.definition.schedule == "0 * * * *", stored.name
        assert "no longer" not in (stored.definition.description or "") and "renamed" not in (stored.definition.description or ""), stored.name
    assert cw.get_run(f"pgcron:{later[0].runid}").job == "j-one"
    assert cw.get_run(f"pgcron:{later[1].runid}").job == "j-three"

    # Working again and then failing again is reported again.
    broken.clear()
    cw.check()
    broken.add("pick:1")
    cw.check()
    assert len(notices()) == 5
    assert notices()[4].startswith("pg_cron job 1: the jobs callback raised")


def test_first_sight_never_judges_history_even_with_a_held_or_cut_off_run_among_the_newest() -> None:
    cron = FakeCron()
    cron.job(1, "nightly", "0 3 * * *")
    for i in range(30):
        cron.add(1, "failed", T0 - (40 - i) * HOUR, T0 - (40 - i) * HOUR + 1000, "ERROR:  old")
    cron.add(1, "failed", None, None, "server restarted")
    for i in range(19):
        start = T0 - int((10 - i / 2) * HOUR)
        cron.add(1, "succeeded", start, start + 1000, "ok")
    capture = Capture()
    cw = client(cron, capture=capture)
    cw.check()
    cw.check()
    assert len(cw.runs("nightly", 500)) == 20, "only the newest twenty are copied"
    assert capture.types() == [], "no alert from history"


def test_a_job_paused_or_renamed_while_missed_closes_missed_with_a_recovery() -> None:
    clock = Clock()
    cron = FakeCron()
    cron.job(1, "hourly", "0 * * * *")
    cron.job(2, "rollup", "0 * * * *")
    cron.add(1, "succeeded", T0 - 3 * HOUR, T0 - 3 * HOUR + 1000)
    cron.add(2, "succeeded", T0 - 3 * HOUR, T0 - 3 * HOUR + 1000)
    capture = Capture()
    cw = client(cron, clock, capture=capture)
    cw.check()
    assert sorted(f"{a.type} {a.job}" for a in capture.alerts) == ["missed hourly", "missed rollup"]
    cron.jobs[0]["active"] = False
    cron.jobs[1]["jobname"] = "rollup-v2"
    clock.advance(MIN)
    result = cw.check()
    assert sorted(f"{a.type} {a.job} {a.title}" for a in result.alerts) == [
        "recovered hourly hourly is no longer scheduled",
        "recovered rollup rollup is no longer scheduled",
    ]
    clock.advance(MIN)
    assert cw.check().alerts == []


def test_a_renamed_job_leaves_no_scheduled_ghost_in_this_process_or_the_next() -> None:
    clock = Clock()
    cron = FakeCron()
    cron.job(1, "rollup", "*/5 * * * *")
    cron.add(1, "succeeded", T0 - 60_000, T0 - 59_000, "1 row")
    store = MemoryStore()
    capture = Capture()
    errors: list[str] = []
    cw = client(cron, clock, store, errors, capture)
    cw.check()
    cron.jobs[0]["jobname"] = "rollup-v2"
    running = cron.add(1, "running", T0 - 1000, None)
    cw.check()
    summary = cw.jobs()
    old = next(j for j in summary if j.name == "rollup")
    assert old.definition.schedule is None, "the old name has no schedule"
    assert "renamed to rollup-v2" in old.definition.description
    assert next(j for j in summary if j.name == "rollup-v2").definition.schedule == "*/5 * * * *"
    assert cw.get_run(f"pgcron:{running.runid}").job == "rollup-v2"
    running.status = "succeeded"
    running.end_time = at(T0)
    clock.advance(HOUR)
    cron.add(1, "succeeded", clock.now() - 2000, clock.now() - 1000, "1 row")
    cw.check()
    assert cw.get_run(f"pgcron:{running.runid}").status == "ok"
    assert not any(a.job == "rollup" for a in capture.alerts), "the old name is never missed"

    # Renamed again while no process watched: the next process retires the name the store still schedules.
    cron.jobs[0]["jobname"] = "rollup-v3"
    cw = client(cron, clock, store, errors, capture)
    clock.advance(MIN)
    cw.check()
    summary = cw.jobs()
    v2 = next(j for j in summary if j.name == "rollup-v2")
    assert v2.definition.schedule is None
    assert "renamed to rollup-v3" in v2.definition.description
    assert next(j for j in summary if j.name == "rollup-v3").definition.schedule == "*/5 * * * *"
    assert cw.runs("rollup-v3") == [], "runs already copied under an old name are not copied again"
    clock.advance(HOUR)
    cw.check()
    assert [f"{a.type} {a.job}" for a in capture.alerts if a.job != "rollup-v3"] == [], "only the job's current name can be missed"
    assert [e for e in errors if "cron." not in e and "row level" not in e] == []


def test_a_run_marked_timeout_by_a_check_is_still_read_and_its_late_finish_recorded() -> None:
    clock = Clock()
    cron = FakeCron()
    cron.job(1, "vacuum", "0 3 * * *")
    capture = Capture()
    cw = client(cron, clock, capture=capture, options={"timeout": "30m"})
    long = cron.add(1, "running", T0, None)
    cw.check()
    assert cw.get_run(f"pgcron:{long.runid}").status == "running"
    clock.advance(45 * MIN)
    cw.check()
    assert cw.get_run(f"pgcron:{long.runid}").status == "timeout"
    assert capture.types() == ["stuck"]
    clock.advance(10 * MIN)
    long.status = "succeeded"
    long.end_time = at(clock.now() - 60_000)
    long.return_message = "VACUUM"
    cw.check()
    done = cw.get_run(f"pgcron:{long.runid}")
    assert [done.status, done.output] == ["ok", "VACUUM"]
    assert capture.types() == ["stuck", "recovered"]
    assert cw.job_summary("vacuum").health == "healthy"


def test_settings_a_role_may_not_read_are_assumed_and_reported_once() -> None:
    cron = FakeCron()
    del cron.settings["cron.timezone"]
    del cron.settings["cron.log_run"]
    cron.job(1, "nightly", "0 3 * * *")
    errors: list[str] = []
    cw = client(cron, errors=errors)
    first = cw.check()
    cw.check()
    assert first.jobs[0].definition.timezone == "UTC"
    assert len([e for e in errors if "cron.timezone" in e]) == 1
    assert not any("log_run" in e for e in errors), "log_run unreadable is taken as on"


# ---------------------------------------------------------------- a real pg_cron

needs_pgcron = pytest.mark.skipif(not PGCRON, reason=NO_PGCRON)


def pg_connect(url: str | None = None, autocommit: bool = True) -> Any:
    import psycopg

    return psycopg.connect(url or PGCRON or "", autocommit=autocommit)


def detail_count(conn: Any, name: str) -> int:
    row = conn.execute(
        "SELECT count(*) FROM cron.job_run_details d JOIN cron.job j USING (jobid) WHERE j.jobname = %s AND d.start_time IS NOT NULL", [name]
    ).fetchone()
    return int(row[0])


@needs_pgcron
def test_against_a_real_pg_cron() -> None:
    conn = pg_connect()
    admin = pg_connect()
    tag = f"cwpy{os.getpid()}"
    names = {"ok": f"{tag}-ok", "fail": f"{tag}-fail", "sleep": f"{tag}-sleep"}
    offset = [0]
    store = MemoryStore()
    capture = Capture()

    def now() -> int:
        return time.time_ns() // 1_000_000 + offset[0]

    def make() -> Cronwatch:
        source = PgCron(conn, jobs=lambda j: (j.jobname or "").startswith(tag), options={"grace": "30s"})
        return Cronwatch(store=store, alerts=[capture], now=now, cron_secret=None, sources=[source])

    try:
        admin.execute("CREATE EXTENSION IF NOT EXISTS pg_cron")
        admin.execute("SELECT cron.schedule(%s, '1 seconds', 'SELECT 1')", [names["ok"]])
        admin.execute("SELECT cron.schedule(%s, '1 seconds', 'SELECT 1/0')", [names["fail"]])
        admin.execute("SELECT cron.schedule(%s, '1 seconds', 'SELECT pg_sleep(3)')", [names["sleep"]])
        time.sleep(3.5)

        cw = make()
        first = cw.check()
        by_name = {j.name: j for j in first.jobs}
        assert by_name[names["ok"]].definition.schedule == "every 1s"
        assert by_name[names["ok"]].definition.timezone == "UTC"
        ok_runs = cw.runs(names["ok"])
        assert len(ok_runs) >= 2, "ok runs imported"
        assert all(r.id.startswith("pgcron:") and r.trigger == "pg_cron" for r in ok_runs)
        assert any(r.status == "ok" and r.output == "1 row" for r in ok_runs)
        assert any(r.status == "failed" and "division by zero" in (r.error or "") for r in cw.runs(names["fail"])), "failure and its message imported"
        assert [f"{a.type} {a.job}" for a in first.alerts] == [f"failed {names['fail']}"]
        assert by_name[names["ok"]].health == "healthy"

        # A run imported while it was going is updated when it finishes.
        running = None
        for _ in range(40):
            row = admin.execute(
                "SELECT d.runid FROM cron.job_run_details d JOIN cron.job j USING (jobid) "
                "WHERE j.jobname = %s AND d.status = 'running' AND d.start_time IS NOT NULL",
                [names["sleep"]],
            ).fetchone()
            running = row and row[0]
            if running:
                break
            time.sleep(0.25)
        assert running, "saw the sleeping job running"
        cw.check()
        assert cw.get_run(f"pgcron:{running}").status == "running"
        time.sleep(3.5)
        cw.check()
        slept = cw.get_run(f"pgcron:{running}")
        assert slept.status == "ok"
        assert slept.duration_ms >= 2900

        # New runs keep arriving; nothing is copied twice, even by a fresh client after a restart.
        before = len(cw.runs(names["ok"], 500))
        time.sleep(2)
        cw.check()
        after = cw.runs(names["ok"], 500)
        assert len(after) > before, "later runs imported"
        assert len(after) == len({r.id for r in after})

        # The ok job is unscheduled: it is gone, not late, so it is never missed.
        admin.execute("SELECT cron.unschedule(%s)", [names["ok"]])
        admin.execute("SELECT cron.alter_job(jobid, active := false) FROM cron.job WHERE jobname = %s", [names["fail"]])
        time.sleep(1.5)
        cw = make()
        cw.check()
        settled = len(cw.runs(names["fail"], 500))
        cw.check()
        assert len(cw.runs(names["fail"], 500)) == settled, "re-import adds nothing"
        assert len(cw.runs(names["fail"], 500)) == min(detail_count(admin, names["fail"]), settled)
        offset[0] = 2 * MIN
        late = cw.check()
        assert not any(a.type == "missed" and a.job == names["ok"] for a in late.alerts), "unscheduled job not missed: it is gone, not late"
        ok_job = next(j for j in late.jobs if j.name == names["ok"])
        assert ok_job.definition.schedule is None
        assert "no longer in cron.job" in ok_job.definition.description
        assert not any(a.job == names["fail"] and a.type == "missed" for a in late.alerts), "paused job not missed"
    finally:
        try:
            admin.execute("SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname LIKE %s", [f"{tag}%"])
        except Exception:  # noqa: BLE001, cleanup only
            pass
        conn.close()
        admin.close()


DETAIL_COLUMNS = "jobid, runid, database, username, command, status, return_message, start_time, end_time"


@needs_pgcron
def test_against_a_real_pg_cron_restart_rows_a_crowded_job_first_sight_and_a_rename() -> None:
    conn = pg_connect()
    tag = f"cwpyrow{os.getpid()}"
    names = {"busy": f"{tag}-busy", "quiet": f"{tag}-quiet", "hist": f"{tag}-hist"}

    def insert(jobid: int, status: str, times: str, message: str) -> Any:
        return conn.execute(
            f"INSERT INTO cron.job_run_details ({DETAIL_COLUMNS}) SELECT %s, nextval('cron.runid_seq'), 'postgres', "
            f"'postgres', 'select 1', %s, %s, {times} RETURNING runid",
            [jobid, status, message],
        ).fetchone()[0]

    try:
        conn.execute("CREATE EXTENSION IF NOT EXISTS pg_cron")
        ids: dict[str, int] = {}
        for name in names.values():
            ids[name] = int(conn.execute("SELECT cron.schedule(%s, '0 3 * * *', 'SELECT 1')", [name]).fetchone()[0])
            # Paused, so pg_cron itself adds no rows while the test writes its own.
            conn.execute("SELECT cron.alter_job(%s, active := false)", [ids[name]])
        # First sight of a job whose newest rows include a run cut off by a restart, and older failures.
        conn.execute(
            f"INSERT INTO cron.job_run_details ({DETAIL_COLUMNS}) SELECT %s, nextval('cron.runid_seq'), 'postgres', 'postgres', "
            "'select 1', 'failed', 'ERROR: old', now() - interval '3 days', now() - interval '3 days' FROM generate_series(1, 5)",
            [ids[names["hist"]]],
        )
        insert(ids[names["hist"]], "failed", "NULL, NULL", "server restarted")
        conn.execute(
            f"INSERT INTO cron.job_run_details ({DETAIL_COLUMNS}) SELECT %s, nextval('cron.runid_seq'), 'postgres', 'postgres', "
            "'select 1', 'succeeded', '1 row', now() - make_interval(mins => 30 - g), now() - make_interval(mins => 30 - g) "
            "FROM generate_series(1, 19) g",
            [ids[names["hist"]]],
        )

        capture = Capture()
        errors: list[str] = []
        cw = Cronwatch(store=MemoryStore(), alerts=[capture], cron_secret=None, on_error=lambda e, _w: errors.append(str(e)),
                       sources=[PgCron(conn, jobs=lambda j: (j.jobname or "").startswith(tag), timezone="UTC")])  # fmt: skip
        cw.check()
        assert len(cw.runs(names["hist"], 500)) == 20, "twenty newest copied"
        assert [a.job for a in capture.alerts] == [], "history is never judged"
        cw.check()
        assert len(cw.runs(names["hist"], 500)) == 20, "and never read again"

        # A restart cuts off a busy job's queued run; the busy job then runs past a page; then the quiet job fails.
        cut = insert(ids[names["busy"]], "failed", "NULL, NULL", "server restarted")
        conn.execute(
            f"INSERT INTO cron.job_run_details ({DETAIL_COLUMNS}) SELECT %s, nextval('cron.runid_seq'), 'postgres', 'postgres', "
            "'select 1', 'succeeded', '1 row', now() - make_interval(secs => 600 - g), now() - make_interval(secs => 600 - g) "
            "FROM generate_series(1, 520) g",
            [ids[names["busy"]]],
        )
        disk = insert(ids[names["quiet"]], "failed", "now(), now()", "ERROR: disk full")
        for _ in range(3):
            cw.check()
        assert cw.get_run(f"pgcron:{cut}").error == "server restarted"
        assert cw.get_run(f"pgcron:{disk}").status == "failed", "the quiet job's failure is read"
        assert any(a.type == "failed" and a.job == names["quiet"] for a in capture.alerts)

        # Renamed in pg_cron: the old name keeps its runs and loses its schedule.
        conn.execute("UPDATE cron.job SET jobname = %s WHERE jobid = %s", [f"{names['quiet']}-v2", ids[names["quiet"]]])
        conn.execute("SELECT cron.alter_job(%s, active := true)", [ids[names["quiet"]]])
        cw.check()
        jobs = cw.jobs()
        old = next(j for j in jobs if j.name == names["quiet"])
        assert old.definition.schedule is None
        assert "renamed to" in old.definition.description
        assert next(j for j in jobs if j.name == f"{names['quiet']}-v2").definition.schedule == "0 3 * * *"
        assert [e for e in errors if "cron." not in e and "row level" not in e] == []
    finally:
        try:
            conn.execute("SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname LIKE %s", [f"{tag}%"])
        except Exception:  # noqa: BLE001, cleanup only
            pass
        conn.close()


@needs_pgcron
def test_against_a_real_pg_cron_a_role_that_may_not_read_cron_settings_never_aborts_the_callers_transaction() -> None:
    admin = pg_connect()
    role = f"cwpyrole{os.getpid()}"
    user = None
    try:
        admin.execute("CREATE EXTENSION IF NOT EXISTS pg_cron")
        admin.execute(f"CREATE ROLE {role} LOGIN PASSWORD 'pw'")
        admin.execute(f"GRANT USAGE ON SCHEMA cron TO {role}")
        admin.execute(f"GRANT SELECT ON cron.job, cron.job_run_details TO {role}")
        parts = urllib.parse.urlsplit(PGCRON or "")
        url = parts._replace(netloc=f"{role}:pw@{parts.hostname}:{parts.port}").geturl()
        user = pg_connect(url, autocommit=False)
        user.execute("SELECT cron.schedule(%s, '0 3 * * *', 'SELECT 1')", [f"{role}-job"])
        user.commit()
        errors: list[str] = []
        cw = Cronwatch(store=MemoryStore(), alerts=[], cron_secret=None, on_error=lambda e, _w: errors.append(str(e)), sources=[PgCron(user)])
        user.execute("SELECT 1")  # the caller's transaction is open
        result = cw.check()
        assert user.execute("SELECT 1 AS one").fetchone()[0] == 1, "the transaction is still usable"
        user.rollback()
        job = next(j for j in result.jobs if j.name == f"{role}-job")
        assert job.definition.timezone == "UTC", "assumed"
        assert job.definition.schedule == "0 3 * * *", "cron.log_run unreadable is taken as on"
        assert any("could not read cron.timezone" in e for e in errors), errors

        # Outside a transaction, the source's reads leave the connection as they found it.
        cw.check()
        from psycopg.pq import TransactionStatus

        assert user.info.transaction_status == TransactionStatus.IDLE
    finally:
        if user is not None:
            user.close()
        # Every job of the role goes before the role: pg_cron's scheduler stops on a job whose role is gone.
        for sql in (f"SELECT cron.unschedule(jobid) FROM cron.job WHERE username = '{role}'", f"DROP OWNED BY {role}", f"DROP ROLE IF EXISTS {role}"):
            try:
                admin.execute(sql)
            except Exception:  # noqa: BLE001, cleanup only
                pass
        admin.close()


@needs_pgcron
def test_against_a_real_pg_cron_through_a_connection_string_and_a_postgres_store() -> None:
    """The whole thing on psycopg: the source from a connection string, the runs in the Postgres store."""
    from cronwatch.stores.postgres import PostgresStore

    from helpers import pg_prefix

    admin = pg_connect()
    tag = f"cwpyurl{os.getpid()}"
    prefix = pg_prefix("pgc")
    store = PostgresStore(PGCRON, prefix=prefix)
    try:
        jobid = int(admin.execute("SELECT cron.schedule(%s, '0 3 * * *', 'SELECT 1')", [tag]).fetchone()[0])
        admin.execute("SELECT cron.alter_job(%s, active := false)", [jobid])
        admin.execute(
            f"INSERT INTO cron.job_run_details ({DETAIL_COLUMNS}) SELECT %s, nextval('cron.runid_seq'), 'postgres', 'postgres', "
            "'select 1', 'succeeded', '1 row', now() - interval '1 minute', now() - interval '59 seconds'",
            [jobid],
        )
        cw = Cronwatch(store=store, alerts=[], cron_secret=None, sources=[PgCron(PGCRON, jobs=[tag], timezone="UTC")])
        cw.check()
        [run] = cw.runs(tag)
        assert [run.status, run.output, run.trigger] == ["ok", "1 row", "pg_cron"]
        assert run.duration_ms == 1000
    finally:
        try:
            admin.execute("SELECT cron.unschedule(%s)", [tag])
        except Exception:  # noqa: BLE001, cleanup only
            pass
        store.close()
        admin.execute(f"DROP TABLE IF EXISTS {prefix}jobs, {prefix}runs, {prefix}state")
        admin.close()
