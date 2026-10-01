"""Ported from the SDK's test/client-hardening.test.ts: store outages, hung
channels, retries, deferred delivery, overlapping runs, validation. Where
the SDK mocks timers, these tests shorten the client's timeouts instead."""

from __future__ import annotations

import logging
import threading
import time
from typing import Any

import pytest

import cronwatch
from cronwatch import Alert, Cronwatch, Run
from cronwatch.stores import MemoryStore
from cronwatch.types import JobDefinition

from helpers import HOUR, MIN, T0, Capture, Clock, Errors, Flaky, Wrapped, boom, make


def test_a_cron_firing_more_often_than_its_grace_is_still_missed() -> None:
    cw, c, alerts = make()
    job = cw.job("often", schedule="*/5 * * * *")  # default grace 10m
    job.run(lambda ctx: None)  # 09:30
    c.advance(14 * MIN)
    assert cw.check().alerts == [], "09:35 is due, grace runs to 09:45"
    c.advance(2 * MIN)
    assert [a.type for a in cw.check().alerts] == ["missed"]
    job.run(lambda ctx: None)
    assert alerts.types() == ["missed", "recovered"]


def test_a_missed_run_whose_next_run_fails_below_the_threshold_still_recovers_later() -> None:
    cw, c, alerts = make()
    job = cw.job("quiet", schedule="every 1h", failures_before_alert=3)
    cw.check()
    c.advance(2 * HOUR)
    cw.check()
    with pytest.raises(RuntimeError):
        job.run(boom())
    assert alerts.types() == ["missed"]
    job.run(lambda ctx: None)
    assert alerts.types() == ["missed", "recovered"]
    assert "after: missed" in alerts.alerts[1].message


def test_a_store_outage_never_stops_the_job_and_store_errors_go_to_on_error() -> None:
    broken = {"upsert_job", "insert_run", "get_state", "set_state", "update_run", "list_runs"}
    errors = Errors()
    cw, _, _ = make(store=Flaky(MemoryStore(), broken), on_error=errors)
    ran = []
    assert cw.run("s", lambda ctx: ran.append(1) or 7) == 7
    with pytest.raises(RuntimeError, match="the job's own"):
        cw.run("s", lambda ctx: ran.append(1) or boom("the job's own")())
    assert len(ran) == 2
    assert errors.wheres and all(w == "recording s" for w in errors.wheres), errors.wheres
    broken.clear()
    cw.run("s", lambda ctx: "back")
    assert len(cw.runs("s")) == 1


def test_a_store_that_fails_to_initialise_is_tried_again_on_the_next_call() -> None:
    inits = [0]

    def init() -> None:
        inits[0] += 1
        if inits[0] == 1:
            raise RuntimeError("not yet")

    store = Wrapped(MemoryStore(), init=init)
    errors = Errors()
    cw, _, _ = make(store=store, on_error=errors)
    assert cw.run("i", lambda ctx: 1) == 1
    assert errors.wheres == ["recording i"]
    # The finished run was written on the retry, once init went through.
    assert inits[0] == 2
    cw.run("i", lambda ctx: 2)
    assert inits[0] == 2
    assert len(cw.runs("i")) == 2


def test_dispatch_does_not_overwrite_a_silence_made_while_an_alert_was_being_sent() -> None:
    holder: list[Cronwatch] = []

    class Silencer:
        name = "silencer"

        def send(self, alert: Alert) -> None:
            holder[0].silence("loud", "1h")

    cw, _, _ = make(alerts=[Silencer()])
    holder.append(cw)
    with pytest.raises(RuntimeError):
        cw.run("loud", boom())
    state = cw.store.get_state("loud")
    assert state.silenced_until is not None, "the silence survived"
    assert state.open == {"failed": T0}
    assert state.last_alert_at == T0


def test_a_hung_channel_times_out_without_holding_up_the_others() -> None:
    errors = Errors()
    good = Capture()
    release = threading.Event()

    class Hung:
        name = "hung"

        def send(self, alert: Alert) -> None:
            release.wait(5)

    cw, _, _ = make(alerts=[Hung(), good], on_error=errors)
    cw._channel_timeout_ms = 100
    started = time.monotonic()
    with pytest.raises(RuntimeError):
        cw.run("h", boom())
    assert time.monotonic() - started < 2
    assert good.types() == ["failed"]
    assert errors.wheres == ["alert channel hung"]
    assert "timed out after 100ms" in errors.messages[0]
    assert cw.store.get_state("h").undelivered == [], "one channel took it: delivered"

    # While it is still going, the hung channel is skipped rather than given another thread.
    with pytest.raises(RuntimeError):
        cw.run("h2", boom())
    assert "skipped: an earlier alert timed out" in errors.messages[1]
    release.set()


def test_triage_is_aborted_when_the_client_stops_waiting_for_it() -> None:
    signals: list[cronwatch.AbortSignal] = []
    release = threading.Event()
    errors = Errors()

    def triage(ctx: cronwatch.TriageContext) -> str:
        signals.append(ctx.signal)
        release.wait(5)
        return "too late"

    cw, _, alerts = make(triage=triage, on_error=errors)
    cw._triage_timeout_ms = 100
    with pytest.raises(RuntimeError):
        cw.run("t", boom())
    assert signals[0].aborted is True
    assert errors.wheres == ["triage for t"]
    assert alerts.types() == ["failed"]
    release.set()


def test_an_alert_no_channel_took_is_retried_once_per_check_until_one_does() -> None:
    down = [True]
    attempts = [0]
    got: list[Alert] = []

    class FlakyChannel:
        name = "flaky"

        def send(self, alert: Alert) -> None:
            attempts[0] += 1
            if down[0]:
                raise ConnectionError("down")
            got.append(alert)

    cw, c, _ = make(alerts=[FlakyChannel()], on_error=lambda e, w: None)
    with pytest.raises(RuntimeError):
        cw.run("r", boom())
    state = cw.store.get_state("r")
    assert len(state.undelivered) == 1
    assert state.last_alert_at is None, "nothing was delivered"
    c.advance(MIN)
    cw.check()
    assert attempts[0] == 2, "one retry per check"
    down[0] = False
    c.advance(MIN)
    result = cw.check()
    assert [a.type for a in result.alerts] == ["failed"]
    assert [a.type for a in got] == ["failed"]
    assert got[0].at == T0, "the same alert, not a new one"
    state = cw.store.get_state("r")
    assert state.undelivered == []
    assert state.last_alert_at == T0 + 2 * MIN
    cw.check()
    assert attempts[0] == 3, "not sent again"


def test_deliver_check_queues_alerts_for_another_processs_check_which_sends_them_with_triage() -> None:
    c = Clock()
    store = MemoryStore()
    unused = Capture()
    triaged = [0]
    # The recording process: no network, so it sends nothing itself.
    recorder = Cronwatch(store=store, now=c.now, alerts=[unused], deliver="check", triage=lambda ctx: "never asked", cron_secret=None)
    job = recorder.job("backup", schedule="40 3 * * *", timezone="UTC")
    with pytest.raises(RuntimeError):
        job.run(boom("disk full"))
    assert unused.types() == [], "nothing sent from the recording process"
    state = store.get_state("backup")
    assert [a.type for a in state.undelivered] == ["failed"]
    assert state.last_alert_at is None
    assert recorder.check().alerts == [], "its own check does not send either"

    # The web server: can send, and has not declared the job.
    sent = Capture()

    def triage(ctx: cronwatch.TriageContext) -> str:
        triaged[0] += 1
        return "The disk is full."

    server = Cronwatch(store=store, now=c.now, alerts=[sent], triage=triage, cron_secret=None)
    c.advance(MIN)
    result = server.check()
    assert [a.type for a in result.alerts] == ["failed"]
    assert sent.types() == ["failed"]
    assert sent.alerts[0].triage == "The disk is full."
    assert sent.alerts[0].at == T0, "the alert from the run, not a new one"
    assert triaged[0] == 1
    state = store.get_state("backup")
    assert state.undelivered == []
    assert state.last_alert_at == T0 + MIN
    server.check()
    assert sent.types() == ["failed"], "sent once"

    # The recovery takes the same route.
    job.run(lambda ctx: None)
    server.check()
    assert sent.types() == ["failed", "recovered"]
    assert triaged[0] == 1, "recoveries are not triaged"


def test_deliver_takes_only_now_or_check() -> None:
    with pytest.raises(ValueError, match='deliver must be "now" or "check", not "later"'):
        Cronwatch(deliver="later")


def test_overlapping_runs_of_one_job_share_its_state_without_losing_updates() -> None:
    cw, _, alerts = make()
    job = cw.job("par", failures_before_alert=2)
    barrier = threading.Barrier(3)

    def fail(_ctx: Any) -> None:
        barrier.wait(5)
        raise RuntimeError("x")

    def worker() -> None:
        try:
            job.run(fail)
        except RuntimeError:
            pass

    threads = [threading.Thread(target=worker) for _ in range(3)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(10)
    assert cw.store.get_state("par").consecutive_failures == 3
    assert alerts.types() == ["failed"], "one alert, not one per run"


def test_job_rejects_numbers_that_would_quietly_turn_a_check_off() -> None:
    cw, _, _ = make()
    nan = float("nan")
    with pytest.raises(ValueError, match="failuresBeforeAlert"):
        cw.job("a", failures_before_alert=nan)
    with pytest.raises(ValueError, match="failuresBeforeAlert"):
        cw.job("a", failures_before_alert=0)
    with pytest.raises(ValueError, match=r"failuresBeforeAlert must be a whole number, 1 or more \(got 1.5\)"):
        cw.job("a", failures_before_alert=1.5)
    with pytest.raises(ValueError, match=r"budget\.cost"):
        cw.job("a", budget={"cost": nan})
    with pytest.raises(ValueError, match=r"budget\.cost .*\(got Infinity\)"):
        cw.job("a", budget={"cost": float("inf")})
    with pytest.raises(ValueError, match=r"budget\.cost"):
        cw.job("a", budget={"cost": -1})
    with pytest.raises(ValueError, match="grace"):
        cw.job("a", grace=nan)
    with pytest.raises(ValueError, match="timeout"):
        cw.job("a", timeout=0)
    with pytest.raises(ValueError, match="maxDuration"):
        cw.job("a", max_duration="0s")
    with pytest.raises(ValueError, match="timezone"):
        cw.job("a", schedule="0 2 * * *", timezone="Mars/Olympus")
    with pytest.raises(ValueError, match="failuresBeforeAlert"):
        Cronwatch(defaults={"failures_before_alert": nan}).job("a")
    cw.job("a", budget={"errors": 0}, failures_before_alert=2, timeout="5m")
    cw.job("b", schedule="0 2 * * *", timezone="america/new_york")


def test_a_returned_string_is_capped_like_logged_output() -> None:
    cw, _, _ = make()
    cw.run("big", lambda ctx: "x" * 40_000)
    [run] = cw.runs("big")
    assert len(run.output) < 17 * 1024
    assert run.output.startswith("[earlier output trimmed]")


def test_runs_takes_a_whole_number_of_runs_in_range() -> None:
    cw, _, _ = make()
    for _ in range(3):
        cw.run("n", lambda ctx: None)
    assert len(cw.runs("n", 2.7)) == 2
    assert len(cw.runs("n", -4)) == 1
    assert len(cw.runs("n", float("nan"))) == 3
    [entry] = cw.jobs_with_runs(2)
    assert len(entry.runs) == 2
    assert entry.job.last_run.id == entry.runs[0].id


def test_an_error_is_written_name_message_and_frames_innermost_first() -> None:
    cw, _, alerts = make()

    def connect() -> None:
        raise ConnectionRefusedError("connect ECONNREFUSED 10.0.0.12:5432")

    with pytest.raises(ConnectionRefusedError):
        cw.run("db", lambda ctx: connect())
    [run] = cw.runs("db")
    lines = run.error.split("\n")
    assert lines[0] == "ConnectionRefusedError: connect ECONNREFUSED 10.0.0.12:5432"
    assert lines[1].startswith("    at connect (") and "test_client_hardening.py:" in lines[1]
    assert len(lines) <= 6
    assert "Error: ConnectionRefusedError" not in alerts.alerts[0].message
    assert "\nConnectionRefusedError: connect ECONNREFUSED" in alerts.alerts[0].message

    with pytest.raises(RuntimeError):
        cw.run("db", boom("two\nlines"))
    assert cw.runs("db")[0].error.startswith("RuntimeError: two\nlines\n    at ")


def test_an_interrupt_is_recorded_as_a_failure_and_raised_again() -> None:
    cw, _, alerts = make()

    def stop(_ctx: Any) -> None:
        raise KeyboardInterrupt

    with pytest.raises(KeyboardInterrupt):
        cw.run("i", stop)
    [run] = cw.runs("i")
    assert run.status == "failed"
    assert run.error.startswith("Interrupted: KeyboardInterrupt\n    at ")
    assert alerts.types() == ["failed"]


def test_the_baseline_reads_past_recent_failures_to_twenty_successful_runs() -> None:
    cw, c, alerts = make()
    job = cw.job("base")

    def at(ms: int, fail: bool = False) -> None:
        def work(_ctx: Any) -> None:
            c.advance(ms)
            if fail:
                raise RuntimeError("x")

        try:
            job.run(work)
        except RuntimeError:
            pass
        c.advance(MIN)

    for _ in range(5):
        at(100_000)
    for _ in range(15):
        at(1_000)
    for _ in range(10):
        at(1_000, True)
    # Fifteen 1s runs alone would make 10s the limit; with the five 100s runs, p95 is 100s.
    at(30_000)
    assert alerts.types() == ["failed", "recovered"]


def test_stop_also_cancels_the_first_check_start_schedules() -> None:
    cw, _, _ = make()
    checks = [0]

    def fake_check() -> Any:
        checks[0] += 1
        return cronwatch.CheckResult(checked_at=0, jobs=[], alerts=[], pruned=0)

    cw.check = fake_check  # type: ignore[method-assign]
    cw._first_tick_s = 0.05
    cw.start_checking()
    cw.stop()
    time.sleep(0.2)
    assert checks[0] == 0
    cw.start_checking()
    deadline = time.monotonic() + 2
    while checks[0] == 0 and time.monotonic() < deadline:
        time.sleep(0.01)
    assert checks[0] == 1
    cw.stop()


def queued(store: MemoryStore, c: Clock, name: str = "backup") -> Cronwatch:
    """A job's failure queued by a deliver="check" process, so a check elsewhere must triage and send it."""
    recorder = Cronwatch(store=store, now=c.now, deliver="check", cron_secret=None)
    with pytest.raises(RuntimeError):
        recorder.run(name, boom("disk full"))
    return recorder


def test_a_diagnosis_made_on_a_retry_is_kept_with_the_queued_alert_and_triage_runs_once_per_alert() -> None:
    c = Clock()
    store = MemoryStore()
    queued(store, c)
    asked = [0]
    down = [True]
    sent: list[Alert] = []

    class FlakyChannel:
        name = "flaky"

        def send(self, alert: Alert) -> None:
            if down[0]:
                raise ConnectionError("down")
            sent.append(alert)

    def triage(ctx: cronwatch.TriageContext) -> str:
        asked[0] += 1
        return "The disk is full."

    server = Cronwatch(store=store, now=c.now, alerts=[FlakyChannel()], triage=triage, cron_secret=None, on_error=lambda e, w: None)
    server.check()
    assert asked[0] == 1
    assert store.get_state("backup").undelivered[0].triage == "The disk is full.", "the stored copy has it"
    server.check()
    server.check()
    assert asked[0] == 1, "not asked again on later retries"
    down[0] = False
    server.check()
    assert [(a.type, a.triage) for a in sent] == [("failed", "The disk is full.")]


@pytest.mark.parametrize("answer", ["raise", "", None])
def test_a_triage_that_raises_or_answers_nothing_is_tried_once_recorded_as_null(answer: Any) -> None:
    c = Clock()
    store = MemoryStore()
    queued(store, c)
    asked = [0]

    def triage(ctx: cronwatch.TriageContext) -> Any:
        asked[0] += 1
        if answer == "raise":
            raise RuntimeError("api down")
        return answer

    class Down:
        name = "down"

        def send(self, alert: Alert) -> None:
            raise ConnectionError("down")

    server = Cronwatch(store=store, now=c.now, cron_secret=None, on_error=lambda e, w: None, alerts=[Down()], triage=triage)
    for _ in range(3):
        server.check()
    assert asked[0] == 1
    stored = store.get_state("backup").undelivered[0]
    assert stored.triage is None and stored.triage_tried
    assert stored.to_dict()["triage"] is None


def test_retries_stop_once_a_check_has_spent_its_budget_and_the_rest_wait() -> None:
    c = Clock()
    store = MemoryStore()
    for name in ("a", "b", "c"):
        queued(store, c, name)
    tried: list[str] = []

    class Slow:
        name = "slow"

        def send(self, alert: Alert) -> None:
            tried.append(alert.job)
            time.sleep(0.12)
            raise TimeoutError("timed out")

    server = Cronwatch(store=store, now=c.now, alerts=[Slow()], cron_secret=None, on_error=lambda e, w: None)
    server._retry_budget_ms = 200  # each attempt takes 120ms and fails: 200ms cover two
    server.check()
    assert tried == ["a", "b"], "the budget covers two attempts"
    assert len(store.get_state("c").undelivered) == 1, "c is still queued"
    tried.clear()
    server.check()
    assert tried == ["a", "b"], "each check has a fresh budget"


def _flaky_channel(sent: list[str], down: list[bool]) -> Any:
    class FlakyChannel:
        name = "flaky"

        def send(self, alert: Alert) -> None:
            if down[0]:
                raise ConnectionError("down")
            sent.append(f"{alert.type}@{alert.at}")

    return FlakyChannel()


def test_an_alert_whose_condition_closed_is_dropped_from_the_retry_queue_a_recovery_whose_conditions_stay_closed_is_sent() -> None:
    down = [True]
    sent: list[str] = []
    cw, c, _ = make(alerts=[_flaky_channel(sent, down)], on_error=lambda e, w: None)
    with pytest.raises(RuntimeError):
        cw.run("s", boom())
    c.advance(MIN)
    cw.run("s", lambda ctx: None)
    assert [a.type for a in cw.store.get_state("s").undelivered] == ["failed", "recovered"]
    down[0] = False
    c.advance(MIN)
    cw.check()
    assert sent == [f"recovered@{T0 + MIN}"], "the failure is over, so only its recovery goes"
    assert cw.store.get_state("s").undelivered == []


def test_an_alert_whose_condition_opened_again_at_another_time_is_dropped_and_so_is_a_recovery_it_undoes() -> None:
    down = [True]
    sent: list[str] = []
    cw, c, _ = make(alerts=[_flaky_channel(sent, down)], on_error=lambda e, w: None)
    with pytest.raises(RuntimeError):
        cw.run("s", boom())
    c.advance(MIN)
    cw.run("s", lambda ctx: None)
    c.advance(MIN)
    with pytest.raises(RuntimeError):
        cw.run("s", boom("again"))
    assert [a.type for a in cw.store.get_state("s").undelivered] == ["failed", "recovered", "failed"]
    down[0] = False
    c.advance(MIN)
    cw.check()
    assert sent == [f"failed@{T0 + 2 * MIN}"]


def test_a_job_that_cannot_be_evaluated_is_reported_and_shown_as_failing_and_the_others_are_checked() -> None:
    errors = Errors()
    cw, c, alerts = make(on_error=errors)
    good = cw.job("good", schedule="every 1h")
    good.run(lambda ctx: None)
    cw.store.upsert_job(JobDefinition({"name": "bad", "schedule": "not a schedule"}), T0)
    cw.store.upsert_job(JobDefinition({"name": "odd", "timeout": "soon"}), T0)
    cw.store.insert_run(Run(id="hung", job="odd", status="running", started_at=T0))
    c.advance(2 * HOUR)
    result = cw.check()
    assert [f"{a.job}:{a.type}" for a in result.alerts] == ["good:missed"]
    assert {j.name: str(j.health) for j in result.jobs} == {"bad": "failing", "good": "late", "odd": "failing"}
    assert errors.wheres == ["checking odd", "checking bad", "checking odd"]
    assert alerts.types() == ["missed"]

    errors.items.clear()
    jobs = cw.jobs()
    assert [(j.name, str(j.health), j.next_expected_at is None) for j in jobs] == [
        ("bad", "failing", True),
        ("good", "late", False),
        ("odd", "failing", True),
    ]
    assert errors.wheres == ["reading bad", "reading odd"]
    assert cw.job_summary("bad").health == "failing"
    cw.silence("bad", "1h")
    assert cw.job_summary("bad").health == "silenced"


def test_trimming_the_undelivered_queue_past_twenty_is_reported() -> None:
    c = Clock()
    errors = Errors()
    cw = Cronwatch(now=c.now, deliver="check", cron_secret=None, on_error=errors)
    for _ in range(10):
        with pytest.raises(RuntimeError):
            cw.run("q", boom())
        cw.run("q", lambda ctx: None)
    assert len(cw.store.get_state("q").undelivered) == 20
    assert errors.wheres == []
    with pytest.raises(RuntimeError):
        cw.run("q", boom())
    assert len(cw.store.get_state("q").undelivered) == 20
    assert errors.wheres == ["alert queue for q"]


def test_start_with_deliver_check_says_once_that_another_process_must_send(caplog: pytest.LogCaptureFixture) -> None:
    cw = Cronwatch(deliver="check", cron_secret=None)
    cw.check = lambda: cronwatch.CheckResult(checked_at=0, jobs=[], alerts=[], pruned=0)  # type: ignore[method-assign]
    with caplog.at_level(logging.WARNING, logger="cronwatch"):
        cw.start_checking()
        cw.stop()
        cw.start_checking()
        cw.stop()
        warnings = [r.getMessage() for r in caplog.records]
        assert len(warnings) == 1
        assert 'deliver="check"' in warnings[0] and "send no alerts" in warnings[0] and "Another process" in warnings[0]
        other = Cronwatch(cron_secret=None)
        other.check = cw.check  # type: ignore[method-assign]
        other.start_checking()
        other.stop()
        assert len(caplog.records) == 1, "a delivering client says nothing"


def test_start_is_a_deprecated_alias_of_start_checking() -> None:
    errors = Errors()
    cw, _, _ = make(on_error=errors)
    cw.check = lambda: cronwatch.CheckResult(checked_at=0, jobs=[], alerts=[], pruned=0)  # type: ignore[method-assign]
    with pytest.warns(DeprecationWarning, match=r"use start_checking\(every\)"):
        cw.start("1m")
    assert cw._ticker is not None
    cw.start_checking("1m")
    with pytest.warns(DeprecationWarning):
        cw.start("5m")
    assert errors.wheres == ["start_checking"], "one interval, whichever name started it"
    cw.stop()
    assert cw._ticker is None


def test_a_second_start_with_another_interval_is_reported_and_ignored() -> None:
    errors = Errors()
    cw, _, _ = make(on_error=errors)
    cw.check = lambda: cronwatch.CheckResult(checked_at=0, jobs=[], alerts=[], pruned=0)  # type: ignore[method-assign]
    cw.start_checking("1m")
    cw.start_checking("1m")
    assert errors.wheres == []
    cw.start_checking("5m")
    assert errors.wheres == ["start_checking"]
    cw.stop()


def test_concurrent_checks_share_one() -> None:
    cw, _, _ = make()
    gate = threading.Event()
    entered = threading.Event()
    runs = [0]
    original = cw._run_check

    def slow_check() -> Any:
        runs[0] += 1
        entered.set()
        gate.wait(5)
        return original()

    cw._run_check = slow_check  # type: ignore[method-assign]
    results: list[Any] = []
    first = threading.Thread(target=lambda: results.append(cw.check()))
    first.start()
    entered.wait(5)
    second = threading.Thread(target=lambda: results.append(cw.check()))
    second.start()
    time.sleep(0.05)
    gate.set()
    first.join(5)
    second.join(5)
    assert runs[0] == 1
    assert len(results) == 2 and results[0] is results[1]


def test_a_redact_that_fails_is_reported_and_the_default_is_used() -> None:
    errors = Errors()
    cw, _, _ = make(redact=lambda text: None, on_error=errors)
    cw.run("r", lambda ctx: ctx.log("password=hunter2"))
    assert cw.runs("r")[0].output == "password=[redacted]"
    assert errors.wheres == ["redact"]
    plain, _, _ = make(redact=False)
    plain.run("r", lambda ctx: ctx.log("password=hunter2"))
    assert plain.runs("r")[0].output == "password=hunter2"
    custom, _, _ = make(redact=lambda text: text.replace("hunter2", "***"))
    custom.run("r", lambda ctx: ctx.log("password=hunter2\x00"))
    assert custom.runs("r")[0].output == "password=***"


class HeldUpsert:
    """A store whose first write of a job's definition waits until it is let
    go, so a test can declare the job again, or ask for another write, while
    that one is under way."""

    def __init__(self, inner: Any) -> None:
        self.entered = threading.Event()
        self.release = threading.Event()
        self._held = False

        def upsert_job(definition: JobDefinition, now: int) -> None:
            if not self._held:
                self._held = True
                self.entered.set()
                assert self.release.wait(5)
            inner.upsert_job(definition, now)

        self.store = Wrapped(inner, upsert_job=upsert_job)


def test_a_handle_kept_from_an_earlier_declaration_writes_the_one_that_stands_not_its_own() -> None:
    store = MemoryStore()
    cw, _, _ = make(store=store)
    earlier = cw.job("a")
    cw.job("a", schedule="every 5m")
    earlier.run(lambda ctx: None)
    assert store.get_job("a").definition.schedule == "every 5m"
    cw.check()
    assert store.get_job("a").definition.schedule == "every 5m"


def test_a_handle_whose_job_was_forgotten_writes_its_own_definition() -> None:
    store = MemoryStore()
    cw, _, _ = make(store=store)
    handle = cw.job("a", schedule="every 5m")
    cw.forget("a")
    handle.run(lambda ctx: None)
    assert store.get_job("a").definition.schedule == "every 5m"


def test_a_declaration_made_while_the_earlier_one_is_being_written_is_still_to_be_written() -> None:
    inner = MemoryStore()
    held = HeldUpsert(inner)
    cw, _, _ = make(store=held.store)
    run = threading.Thread(target=lambda: cw.job("a").run(lambda ctx: None))
    run.start()
    assert held.entered.wait(5)
    cw.job("a", schedule="every 5m")
    held.release.set()
    run.join(5)
    cw.check()
    assert inner.get_job("a").definition.schedule == "every 5m"


def test_a_declarations_write_waits_for_the_earlier_ones_so_the_later_one_stays() -> None:
    inner = MemoryStore()
    held = HeldUpsert(inner)
    cw, _, _ = make(store=held.store)
    run = threading.Thread(target=lambda: cw.job("a").run(lambda ctx: None))
    run.start()
    assert held.entered.wait(5)
    cw.job("a", schedule="every 5m")
    summaries: list[Any] = []
    later = threading.Thread(target=lambda: summaries.append(cw.job_summary("a")))
    later.start()
    # Were the later write not to wait its turn, it would land here, under the earlier one.
    later.join(0.2)
    held.release.set()
    run.join(5)
    later.join(5)
    assert inner.get_job("a").definition.schedule == "every 5m"
    assert summaries[0].definition.schedule == "every 5m"


class HeldUpsertAfterWrite:
    """A store whose first write of a job's definition lands, then waits
    until it is let go, so a forget can delete the row it wrote meanwhile."""

    def __init__(self, inner: Any) -> None:
        self.entered = threading.Event()
        self.release = threading.Event()
        self._held = False

        def upsert_job(definition: JobDefinition, now: int) -> None:
            inner.upsert_job(definition, now)
            if not self._held:
                self._held = True
                self.entered.set()
                assert self.release.wait(5)

        self.store = Wrapped(inner, upsert_job=upsert_job)


def test_a_forget_that_lands_while_a_jobs_first_write_is_under_way_leaves_it_to_be_written_on_its_next_run() -> None:
    inner = MemoryStore()
    held = HeldUpsertAfterWrite(inner)
    cw, _, _ = make(store=held.store)
    handle = cw.job("nightly", schedule="every 5m")
    first = threading.Thread(target=lambda: handle.run(lambda ctx: None))
    first.start()
    assert held.entered.wait(5)
    cw.forget("nightly")
    held.release.set()
    first.join(5)
    assert inner.get_job("nightly") is None, "forgotten after it was written"
    handle.run(lambda ctx: None)
    assert inner.get_job("nightly").definition.schedule == "every 5m", "its next run brings it back"
    assert [j.name for j in cw.jobs()] == ["nightly"]


def test_a_job_forgotten_by_another_process_comes_back_in_a_long_lived_one_that_still_declares_it() -> None:
    store = MemoryStore()
    worker, _, _ = make(store=store)
    web, _, _ = make(store=store)
    nightly = worker.job("nightly", schedule="every 5m")
    nightly.run(lambda ctx: None)

    def forgotten() -> None:
        web.forget("nightly")
        assert store.get_job("nightly") is None

    # Its next run writes it again, so the run is not left without its job.
    forgotten()
    nightly.run(lambda ctx: None)
    assert store.get_job("nightly").definition.schedule == "every 5m"
    assert len(web.runs("nightly")) == 1

    # So does a started run, a check, the board and the job's page in the process that declares it.
    forgotten()
    handle = nightly.start()
    assert store.get_job("nightly") is not None
    handle.finish()
    forgotten()
    worker.check()
    assert store.get_job("nightly") is not None
    forgotten()
    assert [job.name for job in worker.jobs()] == ["nightly"]
    forgotten()
    assert worker.job_summary("nightly").definition.schedule == "every 5m"

    # A process that never declared it does not bring it back.
    forgotten()
    web.check()
    assert web.jobs() == []


PEM = "-----BEGIN PRIVATE KEY-----\n" + "\n".join(f"{'QUJD' * 15}{i:04d}" for i in range(25)) + "\n-----END PRIVATE KEY-----"
BEARER = "Authorization: Bearer opaqueTOKENvalue1234567890"


def test_a_secret_split_by_the_16_kb_cut_is_redacted_whole_redaction_comes_before_the_cap() -> None:
    from cronwatch.output import OUTPUT_CAP

    cw, _, _ = make()

    # The cut lands inside the key's body, and in a second run just after "Bear".
    def pem(ctx: Any) -> None:
        ctx.log("x" * OUTPUT_CAP)
        ctx.log(PEM[:900])
        ctx.log(PEM[900:])
        ctx.log("done")

    cw.run("pem", pem)
    pem_output = cw.runs("pem")[0].output
    assert "QUJD" not in pem_output
    assert pem_output.endswith("[redacted]\ndone")
    tail = "y" * (OUTPUT_CAP - 30)
    cw.run("bearer", lambda ctx: BEARER + "\n" + tail)
    bearer_output = cw.runs("bearer")[0].output
    assert "opaqueTOKEN" not in bearer_output
    assert len(bearer_output) <= OUTPUT_CAP + len("[earlier output trimmed]\n")

    # Errors, recorded runs and flushed lines the same way.
    with pytest.raises(RuntimeError):
        cw.run("thrown", boom(f"{'e' * OUTPUT_CAP} {BEARER} {'z' * (OUTPUT_CAP - 40)}"))
    assert "opaqueTOKEN" not in cw.runs("thrown")[0].error
    cw.job("imported")
    cw.record_run(Run(id="i1", job="imported", status="ok", started_at=1, finished_at=2, duration_ms=1, output=f"{BEARER}\n{tail}", trigger="source"))
    assert "opaqueTOKEN" not in cw.get_run("i1").output
    handle = cw.job("flushed").start()
    handle.log(BEARER)
    handle.log(tail)
    handle.flush()
    assert "opaqueTOKEN" not in cw.get_run(handle.id).output
    handle.finish()
    assert "opaqueTOKEN" not in cw.get_run(handle.id).output


def test_text_past_the_redaction_window_never_keeps_what_came_right_after_its_cut() -> None:
    import re

    from cronwatch.output import OUTPUT_CAP, REDACT_EDGE, redact_and_cap, redact_secrets

    # The window starts part way into a key's body, whose header is before it:
    # the body's rest cannot be told from text, so it is never kept.
    text = "-----BEGIN PRIVATE KEY-----\n" + "QUJD" * 4000 + "\n" + "k" * (OUTPUT_CAP + REDACT_EDGE - 8000)
    kept = redact_and_cap(text, redact_secrets)
    assert kept.startswith("[earlier output trimmed]\n")
    assert len(kept) == len("[earlier output trimmed]\n") + OUTPUT_CAP
    assert "QUJD" not in kept

    # A redaction that shrinks the window cannot pull its first units into view.
    shrunk = redact_and_cap("QUJD" * 100 + "s" * (OUTPUT_CAP + REDACT_EDGE), lambda t: re.sub("s{100}", "", t))
    assert shrunk == "[earlier output trimmed]\n"

    # Short text is redacted whole, then capped as before; NULs go either side of redact.
    assert redact_and_cap("password=x", redact_secrets) == "password=[redacted]"
    assert redact_and_cap("a\x00b", lambda t: t + "\x00") == "ab"
    assert redact_and_cap("x" * (OUTPUT_CAP + 5), redact_secrets) == "[earlier output trimmed]\n" + "x" * OUTPUT_CAP
