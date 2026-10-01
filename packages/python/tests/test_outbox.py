"""The alert outbox, ported from the SDK's test/outbox.test.ts: an alert is
written with the state that opens its condition, so a process that dies
before sending it does not lose it. Several clients over one store stand in
for several processes; a process "dies" when its store stops answering."""

from __future__ import annotations

import threading
from collections.abc import Callable
from typing import Any

import pytest

from cronwatch import Alert, Cronwatch
from cronwatch._evaluate import SEND_LEASE_MS
from cronwatch.stores import MemoryStore

from helpers import MIN, T0, Capture, Clock, Wrapped, boom


class Mortal:
    """A store for a process that is about to die: once kill() is called,
    nothing it asks of the store completes. bury() (at the end of a test)
    lets those calls go, each raising, so nothing more is written."""

    def __init__(self, inner: Any) -> None:
        self._inner = inner
        self._dead = False
        self._gone = threading.Event()

    def kill(self) -> None:
        self._dead = True

    def bury(self) -> None:
        self._gone.set()

    def __getattr__(self, name: str) -> Any:
        value = getattr(self._inner, name)
        if not callable(value):
            return value

        def call(*args: Any, **kwargs: Any) -> Any:
            if self._dead:
                self._gone.wait()
                raise RuntimeError("the process is gone")
            return value(*args, **kwargs)

        return call


class Held:
    """A channel whose sends wait for release, and which says when one has started."""

    name = "held"

    def __init__(self) -> None:
        self.sending = threading.Event()
        self.gate = threading.Event()
        self.sent: list[Alert] = []

    def send(self, alert: Alert, context: Any = None) -> None:
        self.sending.set()
        assert self.gate.wait(10)
        self.sent.append(alert)


def quiet(_error: BaseException, _where: str) -> None:
    pass


def in_background(fn: Callable[[], Any]) -> threading.Thread:
    def call() -> None:
        try:
            fn()
        except Exception:  # noqa: BLE001, the job's own failure
            pass

    thread = threading.Thread(target=call, daemon=True)
    thread.start()
    return thread


def test_the_write_that_opens_a_condition_holds_its_alert_so_a_process_that_dies_before_sending_it_does_not_lose_it() -> None:
    c = Clock()
    shared = MemoryStore()
    mortal = Mortal(shared)
    triaging = threading.Event()
    hang = threading.Event()

    def triage(_ctx: Any) -> str | None:
        # The process dies while its triage call is out: no channel was ever called.
        mortal.kill()
        triaging.set()
        hang.wait(30)
        return None

    dying = Cronwatch(store=mortal, now=c.now, alerts=[Capture()], cron_secret=None, triage=triage, on_error=quiet)
    run = in_background(lambda: dying.run("nightly", boom("disk full")))
    try:
        assert triaging.wait(10)
        state = shared.get_state("nightly")
        assert state.open["failed"] == T0
        assert [(str(e.alert.type), e.alert.at, e.until) for e in state.sending] == [("failed", T0, T0 + SEND_LEASE_MS)]
        assert state.sending[0].alert.triage_tried is False, "triage is made at send time, never stored here"
        assert "triage" not in state.to_dict()["sending"][0]["alert"]
        assert state.undelivered == []

        # Another process's checks leave it alone while its sender's lease runs.
        sent = Capture()
        server = Cronwatch(store=shared, now=c.now, alerts=[sent], cron_secret=None, triage=lambda ctx: "The disk is full.")
        c.advance(MIN)
        server.check()
        assert sent.types() == []

        # Once it has run out, the next check sends it, triaged, once.
        c.set(T0 + SEND_LEASE_MS + 1)
        result = server.check()
        assert [str(a.type) for a in result.alerts] == ["failed"]
        assert [(str(a.type), a.at, a.triage) for a in sent.alerts] == [("failed", T0, "The disk is full.")]
        after = shared.get_state("nightly")
        assert after.sending is None and "sending" not in after.to_dict(), "the key goes once nothing is being sent"
        assert after.undelivered == []
        server.check()
        with pytest.raises(RuntimeError):
            server.run("nightly", boom("again"))
        assert sent.types() == ["failed"], "the condition still alerts once"
    finally:
        hang.set()
        mortal.bury()
        run.join(10)


def test_an_alert_a_channel_took_just_before_its_process_died_is_sent_again_after_the_lease_at_least_once() -> None:
    c = Clock()
    shared = MemoryStore()
    mortal = Mortal(shared)
    first = Capture()
    took = threading.Event()

    class TakesThenDies:
        name = "first"

        def send(self, alert: Alert, context: Any = None) -> None:
            # Accepted, then the process is gone before it records that.
            first.send(alert)
            mortal.kill()
            took.set()

    dying = Cronwatch(store=mortal, now=c.now, alerts=[TakesThenDies()], cron_secret=None, on_error=quiet)
    run = in_background(lambda: dying.run("nightly", boom("x")))
    try:
        assert took.wait(10)
        assert first.types() == ["failed"]
        sent = Capture()
        server = Cronwatch(store=shared, now=c.now, alerts=[sent], cron_secret=None)
        c.set(T0 + SEND_LEASE_MS + 1)
        server.check()
        assert sent.types() == ["failed"], "sent a second time: the one duplicate a crash can cause"
    finally:
        mortal.bury()
        run.join(10)


def test_while_an_alert_is_being_sent_no_check_anywhere_sends_it_too() -> None:
    c = Clock()
    shared = MemoryStore()
    held = Held()
    worker = Cronwatch(store=shared, now=c.now, alerts=[held], cron_secret=None)
    other = Capture()
    server = Cronwatch(store=shared, now=c.now, alerts=[other], cron_secret=None)
    run = in_background(lambda: worker.run("nightly", boom("x")))
    try:
        assert held.sending.wait(10)
        c.advance(MIN)
        server.check()
        # The sending process's own check, too.
        worker.check()
    finally:
        held.gate.set()
        run.join(10)
    assert [str(a.type) for a in held.sent] == ["failed"]
    assert other.types() == []
    state = shared.get_state("nightly")
    assert state.sending is None
    assert state.undelivered == []
    assert state.last_alert_at == T0, "the time the run was judged, as before"
    c.set(T0 + SEND_LEASE_MS + MIN)
    server.check()
    worker.check()
    assert other.types() == []
    assert [str(a.type) for a in held.sent] == ["failed"]


def test_an_alert_no_channel_took_moves_from_the_outbox_to_the_retry_queue_with_its_triage() -> None:
    c = Clock()
    shared = MemoryStore()

    class Down:
        name = "down"

        def send(self, alert: Alert, context: Any = None) -> None:
            raise RuntimeError("down")

    cw = Cronwatch(store=shared, now=c.now, alerts=[Down()], cron_secret=None, on_error=quiet, triage=lambda ctx: "Look at the disk.")
    with pytest.raises(RuntimeError):
        cw.run("nightly", boom("x"))
    state = shared.get_state("nightly")
    assert state.sending is None
    assert [(str(a.type), a.triage) for a in state.undelivered] == [("failed", "Look at the disk.")]


def test_a_process_that_queues_its_alerts_for_a_check_elsewhere_writes_them_with_the_state_that_opens_the_condition() -> None:
    c = Clock()
    shared = MemoryStore()
    writes = [0]

    def compare_and_set_state(state: Any, version: int) -> bool:
        writes[0] += 1
        return bool(shared.compare_and_set_state(state, version))

    counting = Wrapped(shared, compare_and_set_state=compare_and_set_state)
    recorder = Cronwatch(store=counting, now=c.now, deliver="check", cron_secret=None)
    with pytest.raises(RuntimeError):
        recorder.run("backup", boom("disk full"))
    state = shared.get_state("backup")
    assert [str(a.type) for a in state.undelivered] == ["failed"]
    assert state.sending is None
    assert writes[0] == 1, "one write: the failure and its alert together"


def test_a_malformed_outbox_entry_neither_breaks_the_state_nor_is_ever_sent() -> None:
    c = Clock()
    shared = MemoryStore()
    sent = Capture()
    cw = Cronwatch(store=shared, now=c.now, alerts=[sent], cron_secret=None)
    cw.run("nightly", lambda ctx: None)
    from cronwatch.types import JobState

    shared.set_state(JobState.from_dict({"job": "nightly", "open": {}, "consecutiveFailures": 0, "silencedUntil": None, "lastAlertAt": None,
                                         "sending": [None, "x", {"until": 1}, {"alert": 5}]}))  # fmt: skip
    assert len(shared.get_state("nightly").sending) == 4
    cw.check()
    state = shared.get_state("nightly")
    assert state.sending is None
    assert state.undelivered == []
    assert sent.types() == []
