"""Runs that span calls, ported from the SDK's test/start-finish.test.ts and
test/finish-once.test.ts: start(), resume(), flush(), and finish(), and a run
judged once however many processes finish it. Several clients over one
store stand in for several processes; for SQLite each has its own
connection to one file."""

from __future__ import annotations

import re
import threading
from collections.abc import Callable, Iterator
from pathlib import Path
from typing import Any

import pytest

from cronwatch import Cronwatch, Run
from cronwatch.stores import MemoryStore, SqliteStore

from helpers import HOUR, MIN, NO_PG, PG, T0, Capture, Clock, Errors, Flaky, Without, Wrapped, drop_pg_tables, make, pg_prefix


def messages(errors: Errors) -> list[str]:
    return errors.messages


def test_start_records_a_running_run_and_finish_records_it_ok() -> None:
    cw, c, alerts = make()
    job = cw.job("sync", schedule="@hourly")
    run = job.start(trigger="queue")
    assert run.job == "sync"
    assert run.active is True
    stored = cw.get_run(run.id)
    assert stored.status == "running"
    assert stored.trigger == "queue"
    run.log("imported", 12, "rows")
    run.metric("rows", 12)
    c.advance(90_000)
    finished = run.finish()
    assert finished.status == "ok"
    assert finished.duration_ms == 90_000
    assert run.active is False
    [recorded] = cw.runs("sync")
    assert recorded.status == "ok"
    assert recorded.output == "imported 12 rows"
    assert recorded.metrics == {"rows": 12}
    assert alerts.types() == []
    assert cw.job_summary("sync").health == "healthy"


def test_fail_and_finish_error_record_a_failure_and_alert_once() -> None:
    cw, _, alerts = make()
    job = cw.job("import", failures_before_alert=2)
    first = job.start()
    first.fail(RuntimeError("api down"))
    second = job.start()
    run = second.finish({"error": RuntimeError("still down")})
    assert run.status == "failed"
    assert run.error.startswith("RuntimeError: still down")
    assert alerts.types() == ["failed"]
    third = job.start(trigger="retry")
    third.finish({"status": "ok"})
    assert alerts.types() == ["failed", "recovered"]


def test_a_second_finish_is_ignored_and_reported_not_raised() -> None:
    errors = Errors()
    cw, _, alerts = make(on_error=errors)
    job = cw.job("once")
    run = job.start()
    a = run.fail("boom")
    b = run.finish()
    assert a.status == "failed"
    assert a.error == "boom"
    assert b is None
    assert run.finish() is None
    assert alerts.types() == ["failed"]
    assert cw.runs("once")[0].status == "failed"
    assert len(errors.items) == 2
    assert re.search(r"was already finished by this handle; ignored", messages(errors)[0])
    assert errors.wheres[0] == "finishing once"


def test_start_with_an_id_twice_records_one_run_and_returns_a_handle_on_it() -> None:
    errors = Errors()
    cw, _, _ = make(on_error=errors)
    job = cw.job("inngest-fn")
    handles: list[Any] = []
    threads = [threading.Thread(target=lambda: handles.append(job.start(id="01HX-run"))) for _ in range(2)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(5)
    one, two = handles
    assert one.id == "01HX-run" and two.id == "01HX-run"
    again = job.start(id="01HX-run", trigger="ignored")
    assert again.active is True
    assert len(cw.runs("inngest-fn")) == 1
    assert cw.get_run("01HX-run").trigger == "start"
    again.finish("done")
    # Finished elsewhere: this handle's finish is a reported no-op.
    assert one.finish() is None
    assert re.search(r"already finished as ok; ignored", messages(errors)[-1])
    late = job.start(id="01HX-run")
    assert late.active is False
    assert late.finish() is None
    assert len(cw.runs("inngest-fn")) == 1
    with pytest.raises(ValueError, match='belongs to job "inngest-fn"'):
        cw.job("other").start(id="01HX-run")
    with pytest.raises(ValueError, match="run id of 1 to 200 characters"):
        job.start(id="")


@pytest.fixture(params=["memory", "sqlite"])
def pair(request: pytest.FixtureRequest, tmp_path: Path) -> Iterator[tuple[Any, Any]]:
    if request.param == "memory":
        store = MemoryStore()
        yield store, store
    else:
        file = tmp_path / "cw.db"
        a, b = SqliteStore(file), SqliteStore(file)
        yield a, b
        a.close()
        b.close()


def test_resume_in_a_second_client_on_the_same_store_appends_and_finishes(pair: tuple[Any, Any]) -> None:
    c = Clock()
    alerts = Capture()
    errors = Errors()
    first = Cronwatch(store=pair[0], now=c.now, alerts=[alerts], cron_secret=None, on_error=errors)
    second = Cronwatch(store=pair[1], now=c.now, alerts=[alerts], cron_secret=None, on_error=errors)
    options = {"expect": "sent", "budget": {"emails": 100}}
    started = first.job("digest", **options).start(id="evt-1")
    started.log("loaded 40 recipients")
    started.log("token=abc123")
    started.metric("recipients", 40)
    started.flush()
    midway = first.get_run("evt-1")
    assert midway.status == "running"
    assert midway.output == "loaded 40 recipients\ntoken=[redacted]"

    c.advance(5 * MIN)
    second.job("digest", **options)
    resumed = second.resume_run("digest", "evt-1")
    assert resumed.active is True
    assert resumed.started_at == midway.started_at
    resumed.log("sent 40 emails")
    resumed.metric("emails", 40)
    run = resumed.finish()
    assert run.status == "ok"
    assert run.duration_ms == 5 * MIN
    stored = first.get_run("evt-1")
    assert stored.status == "ok"
    assert stored.output == "loaded 40 recipients\ntoken=[redacted]\nsent 40 emails"
    assert stored.metrics == {"recipients": 40, "emails": 40}
    assert alerts.types() == []
    assert errors.items == []


def test_resume_of_an_unknown_or_finished_run_returns_a_handle_whose_finish_is_a_reported_no_op() -> None:
    errors = Errors()
    cw, _, _ = make(on_error=errors)
    job = cw.job("webhook")
    missing = job.resume("nope")
    assert missing.active is False
    assert missing.started_at is None
    missing.log("dropped")
    missing.flush()
    assert missing.finish() is None
    assert re.search(r"run nope of webhook was not found; ignored", messages(errors)[0])
    job.run(lambda ctx: "done")
    [done] = cw.runs("webhook")
    finished = job.resume(done.id)
    assert finished.active is False
    assert finished.fail("late") is None
    assert re.search(r"already finished as ok; ignored", messages(errors)[1])
    assert cw.runs("webhook")[0].status == "ok"
    with pytest.raises(ValueError, match="not declared"):
        cw.resume_run("undeclared", "x")


def test_a_run_never_finished_is_marked_stuck_after_the_jobs_timeout() -> None:
    cw, c, alerts = make()
    job = cw.job("callback", timeout="30m")
    run = job.start()
    c.advance(29 * MIN)
    cw.check()
    assert cw.get_run(run.id).status == "running"
    c.advance(2 * MIN)
    cw.check()
    stored = cw.get_run(run.id)
    assert stored.status == "timeout"
    assert "Still running after 30m" in stored.error
    assert alerts.types() == ["stuck"]


class HeldChannel:
    """A channel whose sends wait for `gate`, and which sets `entered` when one has started."""

    name = "held"

    def __init__(self, events: list[str] | None = None) -> None:
        self.entered = threading.Event()
        self.gate = threading.Event()
        self.events = events if events is not None else []

    def send(self, alert: Any, context: Any = None) -> None:
        self.entered.set()
        assert self.gate.wait(10)
        self.events.append("sent")


def test_close_waits_for_a_check_under_way_before_it_closes_the_store() -> None:
    events: list[str] = []
    held = HeldChannel(events)
    store = Wrapped(MemoryStore(), close=lambda: events.append("closed"))
    cw, c, _ = make(alerts=[held], store=store)
    cw.job("callback", timeout="30m").start()
    c.advance(31 * MIN)
    results: list[Any] = []
    check = threading.Thread(target=lambda: results.append(cw.check()))
    check.start()
    assert held.entered.wait(5)
    flight = cw._checking
    assert flight is not None
    waiting = threading.Event()
    wait = flight.wait

    def watched() -> None:
        waiting.set()
        wait()

    flight.wait = watched  # type: ignore[method-assign]
    closing = threading.Thread(target=cw.close)
    closing.start()
    assert waiting.wait(5), "close waits on the check under way"
    assert events == []
    held.gate.set()
    closing.join(5)
    check.join(5)
    assert events == ["sent", "closed"]
    assert [str(a.type) for a in results[0].alerts] == ["stuck"]
    # With no check under way it closes straight away.
    cw.close()
    assert events == ["sent", "closed", "closed"]


def test_close_waits_for_the_interval_thread_whose_tick_has_woken_but_not_yet_checked() -> None:
    events: list[str] = []
    store = Wrapped(MemoryStore(), close=lambda: events.append("closed"))
    cw, _, _ = make(store=store)
    cw._first_tick_s = 0.0
    entered = threading.Event()
    gate = threading.Event()
    original = cw.check

    def woken() -> Any:
        # The tick has woken; its check (and the flight close() waits on) is not made yet.
        entered.set()
        assert gate.wait(10)
        result = original()
        events.append("checked")
        return result

    cw.check = woken  # type: ignore[method-assign]
    cw.start_checking("5m")
    assert entered.wait(5)
    closing = threading.Thread(target=cw.close)
    closing.start()
    closing.join(0.2)
    gate.set()
    closing.join(5)
    assert events == ["checked", "closed"]


def test_close_from_inside_a_check_does_not_wait_on_itself() -> None:
    closed: list[bool] = []
    store = Wrapped(MemoryStore(), close=lambda: closed.append(True))
    cw, _, _ = make(store=store)
    cw.sources.append(type("Closer", (), {"name": "closer", "sync": lambda self, host: host.close()})())
    cw.check()
    assert closed == [True]


def test_lines_flushed_while_a_check_marks_earlier_runs_stuck_are_kept_on_the_run_it_marks_next() -> None:
    held = HeldChannel()
    cw, c, _ = make(alerts=[held])
    first = cw.job("first", timeout="30m").start()
    c.advance(1000)
    second = cw.job("second", timeout="30m").start()
    second.log("early line")
    second.metric("rows", 1)
    second.flush()
    c.advance(31 * MIN)
    check = threading.Thread(target=cw.check)
    check.start()
    # The first stuck run's alert is being sent; the second is still running, and flushes.
    assert held.entered.wait(5)
    second.log("important progress line")
    second.metric("rows", 2)
    second.flush()
    held.gate.set()
    check.join(10)
    stored = cw.get_run(second.id)
    assert stored.status == "timeout"
    assert stored.output == "early line\nimportant progress line"
    assert stored.metrics == {"rows": 2}
    assert cw.get_run(first.id).status == "timeout"


def test_a_late_success_after_a_timeout_mark_closes_stuck_and_recovers_a_late_failure_does_not_count_twice() -> None:
    cw, c, alerts = make()
    job = cw.job("slowpoke", timeout="10m", failures_before_alert=2)
    first = job.start()
    c.advance(11 * MIN)
    cw.check()
    assert alerts.types() == []
    failed = first.fail(RuntimeError("gave up"))
    assert failed.status == "failed"
    assert cw.get_run(first.id).error.split("\n")[0] == "RuntimeError: gave up", "the run keeps its real error"
    assert alerts.types() == [], "the late failure did not count as a second one"

    second = job.start()
    c.advance(11 * MIN)
    cw.check()
    assert alerts.types() == ["stuck"]
    resumed = cw.resume_run("slowpoke", second.id)
    assert resumed.active is True, "a run marked timeout can still be finished late"
    late = resumed.finish()
    assert late.status == "ok"
    assert alerts.types() == ["stuck", "recovered"]
    assert second.finish() is None, "the handle that started it sees it finished elsewhere"


def test_expect_is_applied_at_finish_to_the_logged_lines_or_the_string_passed() -> None:
    cw, _, alerts = make()
    job = cw.job("export", expect=re.compile(r"wrote \d+ files"))
    quiet = job.start()
    run = quiet.finish({"status": "ok", "result": "nothing to do"})
    assert run.status == "failed"
    assert run.output == "nothing to do"
    assert "did not match" in run.error
    assert alerts.types() == ["failed"]

    busy = job.start()
    busy.log("wrote 3 files")
    busy.flush()
    resumed = job.resume(busy.id)
    assert resumed.finish("uploaded").status == "ok", "lines flushed earlier count toward expect"
    assert alerts.types() == ["failed", "recovered"]

    keyword = job.start()
    assert keyword.finish(result="wrote 9 files").status == "ok"
    erred = job.start()
    assert erred.finish(error=ValueError("bad row")).error.startswith("ValueError: bad row")


def test_a_store_failing_during_start_does_not_raise_finish_records_the_run_once_the_store_is_back() -> None:
    broken = {"insert_run"}
    errors = Errors()
    cw, c, alerts = make(store=Flaky(MemoryStore(), broken), on_error=errors)
    job = cw.job("backup", schedule="@hourly")
    run = job.start()
    assert run.active is True
    assert errors.wheres[0] == "recording backup"
    assert cw.get_run(run.id) is None
    run.log("copied")
    run.flush()  # nothing stored to append to; kept for finish
    broken.clear()
    c.advance(HOUR // 2)
    finished = run.finish()
    assert finished.status == "ok"
    stored = cw.get_run(run.id)
    assert stored.status == "ok"
    assert stored.output == "copied"
    assert stored.duration_ms == HOUR // 2
    assert alerts.types() == []


def test_a_store_failing_at_finish_is_reported_not_raised_and_the_handle_can_finish_again() -> None:
    broken: set[str] = set()
    errors = Errors()
    cw, _, _ = make(store=Flaky(MemoryStore(), broken), on_error=errors)
    job = cw.job("flaky")
    run = job.start()
    run.log("working")
    broken.update({"get_run", "update_run", "update_run_if"})
    run.flush()
    assert errors.wheres[-1] == "flushing flaky"
    assert run.finish() is None, "nothing recorded"
    assert "finishing flaky" in errors.wheres
    assert run.active is True, "still active, to finish again"
    # The read works but the write fails: still retryable.
    broken.discard("get_run")
    assert run.finish() is None
    assert run.active is True
    broken.clear()
    assert cw.get_run(run.id).status == "running", "nothing written yet"
    finished = run.finish()
    assert finished.status == "ok"
    assert finished.output == "working", "the lines logged before the failures are kept"
    assert run.active is False
    assert run.finish() is None, "finished once only"


# ---------------------------------------------------------------- finish once


def failed_run(run_id: str, job: str, started_at: int) -> Run:
    return Run(
        id=run_id,
        job=job,
        status="failed",
        started_at=started_at,
        finished_at=started_at + 1000,
        duration_ms=1000,
        error="ERROR: deadlock detected",
        trigger="pg_cron",
    )


class Backend:
    """Several stores over one database, as several processes would have."""

    def __init__(self, kind: str, tmp_path: Path) -> None:
        self.kind = kind
        self.file = tmp_path / "once.db"
        self.shared = MemoryStore()
        self.opened: list[Any] = []
        self.prefix = pg_prefix("once")

    def open(self) -> Any:
        if self.kind == "memory":
            return self.shared
        if self.kind == "postgres":
            from cronwatch.stores.postgres import PostgresStore

            store: Any = PostgresStore(PG, prefix=self.prefix)
        else:
            store = SqliteStore(self.file)
        self.opened.append(store)
        return store

    def done(self) -> None:
        for store in self.opened:
            store.close()
        if self.kind == "postgres":
            drop_pg_tables(self.prefix)


@pytest.fixture(params=["memory", "sqlite", pytest.param("postgres", marks=pytest.mark.skipif(not PG, reason=NO_PG))])
def backend(request: pytest.FixtureRequest, tmp_path: Path) -> Iterator[Backend]:
    b = Backend(request.param, tmp_path)
    yield b
    b.done()


def client(store: Any, now: Callable[[], int]) -> tuple[Cronwatch, Capture, Errors]:
    alerts = Capture()
    errors = Errors()
    return Cronwatch(store=store, now=now, alerts=[alerts], cron_secret=None, on_error=errors), alerts, errors


def in_parallel(*calls: Callable[[], Any]) -> list[Any]:
    results: list[Any] = [None] * len(calls)
    barrier = threading.Barrier(len(calls))

    def run(i: int, call: Callable[[], Any]) -> None:
        barrier.wait(5)
        results[i] = call()

    threads = [threading.Thread(target=run, args=(i, call)) for i, call in enumerate(calls)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(10)
    return results


def test_two_processes_finishing_one_run_one_records_and_judges_it_the_other_reports_it(backend: Backend) -> None:
    c = Clock()
    one, two = client(backend.open(), c.now), client(backend.open(), c.now)
    jobs = [p[0].job("webhook-ingest", failures_before_alert=2) for p in (one, two)]
    jobs[0].start(id="delivery-1")
    h1 = one[0].resume_run("webhook-ingest", "delivery-1")
    h2 = two[0].resume_run("webhook-ingest", "delivery-1")
    c.advance(MIN)
    results = in_parallel(lambda: h1.fail(RuntimeError("upstream 502")), lambda: h2.fail(RuntimeError("upstream 502")))
    assert len([r for r in results if r]) == 1, "one finish recorded"
    assert any(re.search("already finished as failed; ignored", m) for m in one[2].messages + two[2].messages)
    assert len(one[0].runs("webhook-ingest")) == 1
    assert one[0].store.get_state("webhook-ingest").consecutive_failures == 1, "the failure counted once"
    assert one[1].types() + two[1].types() == [], "one failure is below failures_before_alert 2"


def test_two_processes_recording_one_finished_run_from_a_source_it_is_judged_once(backend: Backend) -> None:
    c = Clock()
    # Both processes read the run while it is still running, then race to finish it.
    armed = [False]
    both_read = threading.Barrier(2)

    def reading_together(store: Any) -> Any:
        waited = [False]

        def get_run(run_id: str) -> Any:
            run = store.get_run(run_id)
            if armed[0] and not waited[0]:
                waited[0] = True
                both_read.wait(5)
            return run

        return Wrapped(store, get_run=get_run)

    one = client(reading_together(backend.open()), c.now)
    two = client(reading_together(backend.open()), c.now)
    for p in (one, two):
        p[0].job("db:rollup", failures_before_alert=2)
    t = T0 - MIN
    running = failed_run("pgcron:9", "db:rollup", t)
    running.status, running.finished_at, running.duration_ms, running.error = "running", None, None, None
    one[0].record_run(running)
    two[0].jobs()
    done = failed_run("pgcron:9", "db:rollup", t)
    armed[0] = True
    in_parallel(lambda: one[0].record_run(done), lambda: two[0].record_run(done))
    armed[0] = False
    assert one[0].store.get_state("db:rollup").consecutive_failures == 1
    assert one[1].types() + two[1].types() == []
    assert any(re.search("pgcron:9 of db:rollup was already finished as failed; ignored", m) for m in one[2].messages + two[2].messages)


def test_many_processes_starting_and_finishing_one_id_exactly_one_finish_is_recorded(backend: Backend) -> None:
    c = Clock()
    clients = [client(backend.open(), c.now) for _ in range(6)]
    jobs = [p[0].job("ingest") for p in clients]
    clients[0][0].check()
    for k in range(5):
        run_id = f"evt_{k}"
        handles = in_parallel(*[lambda j=j: j.start(id=run_id) for j in jobs])
        finished = in_parallel(*[lambda h=h, i=i: h.finish(f"worker {i}") for i, h in enumerate(handles)])
        assert len([f for f in finished if f]) == 1, f"{run_id}: one finish recorded"
    runs = clients[0][0].runs("ingest", 500)
    assert len(runs) == 5
    assert {str(r.status) for r in runs} == {"ok"}
    unexpected = [m for p in clients for m in p[2].messages if "already finished" not in m]
    assert unexpected == []


def test_a_store_without_update_run_if_falls_back_to_a_read_and_a_write() -> None:
    store = Without(MemoryStore(), ["update_run_if"])
    cw, _, errors = client(store, Clock().now)
    job = cw.job("plain")
    h = job.start(id="p1")
    assert h.finish("done").status == "ok"
    assert job.resume("p1").finish("again") is None
    assert any("already finished" in m for m in errors.messages)


def test_record_run_a_run_a_check_marked_timeout_takes_its_late_finish_as_a_handles_would() -> None:
    from cronwatch._js import date_utc

    c = Clock(date_utc(2026, 0, 1, 3, 0))
    cw, alerts, _ = client(MemoryStore(), c.now)
    cw.job("db:vacuum", schedule="0 3 * * *", timeout="30m")

    def run(**fields: Any) -> dict[str, Any]:
        base = {"id": "pgcron:77", "job": "db:vacuum", "startedAt": c.now(), "error": None, "output": None, "metrics": {}, "trigger": "pg_cron"}
        return {**base, **fields}

    started = c.now()
    cw.record_run(run(status="running", finishedAt=None, durationMs=None))
    c.advance(45 * MIN)
    cw.check()
    assert cw.get_run("pgcron:77").status == "timeout"
    c.advance(15 * MIN)
    cw.record_run(run(startedAt=started, status="ok", finishedAt=c.now() - 5 * MIN, durationMs=55 * MIN, output="VACUUM"))
    cw.check()
    stored = cw.get_run("pgcron:77")
    assert stored.status == "ok"
    assert stored.output == "VACUUM"
    assert cw.job_summary("db:vacuum").health == "healthy"
    assert alerts.types() == ["stuck", "recovered"]

    # A late failure is written but not counted twice.
    other_start = c.now()
    cw.record_run(run(id="pgcron:78", startedAt=other_start, status="running", finishedAt=None, durationMs=None))
    c.advance(45 * MIN)
    cw.check()
    cw.record_run(run(id="pgcron:78", startedAt=other_start, status="failed", finishedAt=c.now(), durationMs=45 * MIN, error="ERROR: canceled"))
    assert cw.get_run("pgcron:78").status == "failed"
    assert cw.store.get_state("db:vacuum").consecutive_failures == 1
    assert alerts.types() == ["stuck", "recovered", "stuck"]


def test_record_run_leaves_a_stored_run_of_another_job_alone_and_reports_it() -> None:
    cw, alerts, errors = client(MemoryStore(), Clock().now)
    a = cw.job("webhook-job")
    cw.job("db:nightly")
    h = a.start(id="run-43")
    sent = cw.record_run(Run(id="run-43", job="db:nightly", status="ok", started_at=T0 - 1000, finished_at=T0, duration_ms=1000, trigger="pg_cron"))
    assert sent == []
    stored = cw.get_run("run-43")
    assert stored.job == "webhook-job"
    assert stored.status == "running"
    assert any(re.search(r'run-43 of db:nightly belongs to job "webhook-job"; ignored', m) for m in errors.messages)
    assert h.finish().status == "ok"
    assert alerts.types() == []


def test_start_and_resume_refuse_ids_in_the_pg_cron_sources_namespace() -> None:
    cw, _, _ = client(MemoryStore(), Clock().now)
    job = cw.job("webhook-job")
    with pytest.raises(ValueError, match='cannot take a run id starting with "pgcron:"'):
        job.start(id="pgcron:42")
    with pytest.raises(ValueError, match='cannot take a run id starting with "pgcron:"'):
        job.resume("pgcron:42")
    with pytest.raises(ValueError, match="pgcron:"):
        cw.resume_run("webhook-job", "pgcron:db:42")
    assert job.start(id="pgcron-42").active is True, "only the prefix with its colon is reserved"


def test_a_run_id_with_a_nul_is_refused_wherever_one_is_taken() -> None:
    """No store could hold a NUL (Postgres refuses it)."""
    cw, _, _ = client(MemoryStore(), Clock().now)
    job = cw.job("webhook-job")
    with pytest.raises(ValueError, match=r"start\(\) cannot take a run id containing a NUL character"):
        job.start(id="run\x00one")
    with pytest.raises(ValueError, match=r"resume\(\) cannot take a run id containing a NUL character"):
        job.resume("run\x00one")
    run = {"id": "x\x00y", "job": "webhook-job", "status": "ok", "startedAt": 1, "finishedAt": 2, "durationMs": 1, "metrics": {}, "trigger": "run"}
    with pytest.raises(ValueError, match="record_run: run ids cannot contain a NUL character"):
        cw.record_run(run)
    assert cw.runs("webhook-job") == []


def test_start_with_an_id_another_job_holds_fails_the_same_whether_its_start_is_in_flight_or_done() -> None:
    cw, _, _ = client(MemoryStore(), Clock().now)
    a = cw.job("import-a")
    b = cw.job("import-b")
    a.start(id="evt_123")
    with pytest.raises(ValueError, match='belongs to job "import-a", not "import-b"'):
        b.start(id="evt_123")
    # The same job at once still shares one start.
    x, y = in_parallel(lambda: a.start(id="evt_9"), lambda: a.start(id="evt_9"))
    assert x.id == y.id == "evt_9"
    assert len(cw.runs("import-a")) == 2
    assert cw.get_run("evt_123").job == "import-a"


def test_a_handle_resumed_while_the_store_failed_cannot_finish_or_flush_another_jobs_run() -> None:
    inner = MemoryStore()
    fail = [False]

    def get_run(run_id: str) -> Any:
        if fail[0]:
            fail[0] = False
            raise RuntimeError("blip")
        return inner.get_run(run_id)

    cw, _, errors = client(Wrapped(inner, get_run=get_run), Clock().now)
    billing = cw.job("billing")
    webhook = cw.job("webhook")
    billing.start(id="run-7")
    fail[0] = True
    h = webhook.resume("run-7")
    assert h.active is True, "unknown yet: the read failed"
    h.log("attacker line")
    h.flush()
    assert any(re.search(r'run-7 of webhook belongs to job "billing"; ignored', m) for m in errors.messages)
    assert h.finish("ok") is None
    stored = inner.get_run("run-7")
    assert (stored.job, str(stored.status), stored.output) == ("billing", "running", None)


def test_expect_at_finish_sees_an_early_line_even_after_flushes_as_run_would() -> None:
    cw, _, _ = client(MemoryStore(), Clock().now)
    job = cw.job("export", expect="connected to warehouse")

    def work(ctx: Any) -> None:
        ctx.log("connected to warehouse")
        for i in range(400):
            ctx.log(f"row batch {i} ".ljust(60, "."))

    job.run(work)
    assert cw.runs("export")[0].status == "ok"
    h = job.start()
    h.log("connected to warehouse")
    for i in range(400):
        h.log(f"row batch {i} ".ljust(60, "."))
        if i % 100 == 99:
            h.flush()
    run = h.finish()
    assert run.status == "ok", run.error
    assert "connected to warehouse" not in run.output, "the stored output kept only the tail"


def test_a_flush_never_undoes_a_finish_written_while_it_read() -> None:
    inner = MemoryStore()
    finish_first: list[Callable[[], Any]] = []

    def get_run(run_id: str) -> Any:
        run = inner.get_run(run_id)
        if finish_first:
            finish_first.pop()()
        return run

    cw, _, _ = client(Wrapped(inner, get_run=get_run), Clock().now)
    job = cw.job("sync")
    h = job.start(id="s1")
    h.log("halfway")
    other = job.resume("s1")
    finish_first.append(lambda: other.finish("done elsewhere"))
    h.flush()
    stored = inner.get_run("s1")
    assert stored.status == "ok", "still finished"
    assert stored.output == "done elsewhere"


def test_a_run_finished_while_a_check_marks_it_timeout_is_judged_once() -> None:
    c = Clock()
    inner = MemoryStore()
    race: list[Callable[[], Any]] = []

    def running_runs() -> Any:
        runs = inner.running_runs()
        if race:
            race.pop()()
        return runs

    cw, alerts, _ = client(Wrapped(inner, running_runs=running_runs), c.now)
    job = cw.job("long", timeout="5m")
    h = job.start()
    c.advance(10 * MIN)
    race.append(lambda: h.finish("finally"))
    cw.check()
    assert cw.get_run(h.id).status == "ok"
    assert alerts.types() == [], "not marked stuck over a finish"
