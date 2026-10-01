"""Checks that a schedule converted from a scheduler's own (Celery beat's
crontab, APScheduler's CronTrigger) makes CronWatch expect runs exactly when
the scheduler makes them, as the gem checks Solid Queue's and sidekiq-cron's
against Fugit (packages/ruby/lib/cronwatch/scheduler.rb): the scheduler's own
runs, from its own code, walked beside CronWatch's fires around every clock
change in the next few years and from the start of each month of a sample
year, so the answer does not depend on when the app starts.

Between two runs of the scheduler, CronWatch must not want one of its own, or
it would report it missed: a fire CronWatch has and the scheduler does not (a
time the scheduler skips when clocks go forward, a run its steps drop that
day) is refused unless the run before it covers it (a minute of early slack,
as in a burst such as "* 5 * * *", or a fire moved past a spring-forward
jump). Away from clock changes every run the scheduler makes must also be one
CronWatch expects; near one, the scheduler may run a repeated time twice,
which CronWatch takes as an early run.
"""

from __future__ import annotations

import time
from collections.abc import Callable

from . import _js, _zone
from ._schedule import ParsedSchedule, _due_after_run, _fire_after

__all__ = [
    "CHANGE_WINDOW_MS",
    "HORIZON_YEARS",
    "NeverFires",
    "Runs",
    "SAMPLE_MONTHS",
    "SAMPLE_RUNS",
    "SAMPLE_YEAR",
    "ScheduleError",
    "check_fires",
    "transitions",
]

#: How far ahead the daylight saving check looks, and how far either side of
#: each clock change it compares the scheduler's runs with CronWatch's.
HORIZON_YEARS = 5
CHANGE_WINDOW_MS = 2 * 86_400_000
#: Away from clock changes, SAMPLE_RUNS runs from the start of each month of a fixed year are compared too.
SAMPLE_YEAR = 2026
SAMPLE_MONTHS = 12
SAMPLE_RUNS = 8

#: The scheduler's runs: the one at or before `start` and every one after it
#: up to the first past `end`, or SAMPLE_RUNS of them after `start` when `end`
#: is None. Epoch milliseconds, ascending.
Runs = Callable[[int, "int | None"], list[int]]


class ScheduleError(ValueError):
    """A schedule that cannot be read, found or converted exactly."""


class NeverFires(Exception):
    """Raised by a Runs function for a schedule that never fires again."""


def transitions(zone: str, start_ms: int, end_ms: int) -> list[tuple[int, int, int]]:
    """The zone's clock changes between two instants: (epoch ms, offset before, offset after), offsets in seconds."""
    found: list[tuple[int, int, int]] = []
    step = 86_400
    at = start_ms // 1000
    end = end_ms // 1000
    before = _zone.offset(at, zone)
    while at < end:
        following = min(at + step, end)
        after = _zone.offset(following, zone)
        if after != before:
            lo, hi = at, following
            while hi - lo > 1:
                mid = (lo + hi) // 2
                if _zone.offset(mid, zone) == before:
                    lo = mid
                else:
                    hi = mid
            found.append((hi * 1000, before, after))
            before = after
        at = following
    return found


def _year_start(year: int) -> int:
    return _js.date_utc(year, 0, 1)


def check_fires(runs: Runs, parsed: ParsedSchedule, where: str, scheduler: str, *, daily: bool, now_ms: int | None = None) -> None:
    """Raises ScheduleError where CronWatch would not expect runs when the
    scheduler makes them. `daily` is a cron that names no day or month, which
    meets every clock change of one kind alike, so one of each is walked."""
    zone = parsed.timezone or "UTC"
    now = now_ms if now_ms is not None else time.time_ns() // 1_000_000
    year = _zone.wall(now // 1000, "UTC")[0]
    try:
        seen: set[tuple[int, int]] = set()
        for at, before, after in transitions(zone, _year_start(year), _year_start(year + HORIZON_YEARS + 1)):
            kind = (((at // 1000) + before) % 86_400, after - before)
            if daily and kind in seen:
                continue
            seen.add(kind)
            start = at - CHANGE_WINDOW_MS
            end = start + 2 * CHANGE_WINDOW_MS
            # Near a change only CronWatch's own fires can be refused, so a
            # stretch where it has none needs no walk.
            first = _fire_after(parsed, start - 1)
            if first is None or first > end:
                continue
            _compare_runs(runs(start, end), parsed, False, where, scheduler)

        compared_until: int | None = None
        for month in range(SAMPLE_MONTHS):
            start = _js.date_utc(SAMPLE_YEAR, month, 1)
            if compared_until is not None and start < compared_until:
                continue  # a sparse cron's earlier sample reached past this month
            found = runs(start, None)
            if not found:
                continue
            compared_until = found[-1]
            near = bool(transitions(zone, found[0] - 86_400_000, found[-1] + 86_400_000))
            _compare_runs(found, parsed, not near, where, scheduler)
    except NeverFires as error:
        raise ScheduleError(f"{where} never fires: {error}") from None


def _cronwatch_fires(parsed: ParsedSchedule, start: int, end: int) -> list[int]:
    """CronWatch's fires after `start`, up to and including `end`."""
    fires: list[int] = []
    at = start
    while True:
        fire = _fire_after(parsed, at)
        if fire is None or fire > end:
            return fires
        fires.append(fire)
        at = fire


def _compare_runs(runs: list[int], parsed: ParsedSchedule, strict: bool, where: str, scheduler: str) -> None:
    """Refuses the conversion where, after one of the scheduler's runs,
    CronWatch would want a run before the scheduler's next (or, when
    `strict`, where the scheduler's next is not a time CronWatch fires)."""
    if len(runs) < 2:
        return
    fires = _cronwatch_fires(parsed, runs[0], runs[-1])
    expected = set(fires) if strict else set()
    i = 0
    for at, following in zip(runs, runs[1:], strict=False):
        while i < len(fires) and fires[i] <= at:
            i += 1
        own = i >= len(fires) or fires[i] < following
        unexpected = strict and following not in expected
        if not own and not unexpected:
            continue
        due = _due_after_run(parsed, at)
        if not unexpected and due is not None and due >= following:
            continue
        _mismatch(parsed, at, following, due, where, scheduler)


def _stamp(ms: int, zone: str) -> str:
    y, mo, d, h, mi, s = _zone.wall(ms // 1000, zone)
    return f"{y:04d}-{mo:02d}-{d:02d} {h:02d}:{mi:02d}:{s:02d}"


def _mismatch(parsed: ParsedSchedule, at: int, following: int, due: int | None, where: str, scheduler: str) -> None:
    zone = parsed.timezone or "UTC"
    skipped = None
    if due is not None:
        for change_at, before, after in transitions(zone, due - 86_400_000, due + 1000):
            gap = after - before
            if gap > 0 and due < change_at + gap * 1000:
                skipped = (change_at, before, after)
                break
    if skipped is None:
        raise ScheduleError(
            f"{where} is {_js.dumps(parsed.source)} in {zone}, but after a run at {_stamp(at, zone)} {scheduler} "
            f"runs it next at {_stamp(following, zone)} and CronWatch would expect {_stamp(due, zone) if due is not None else 'nothing'}, "
            "so it cannot be converted exactly; give the job a schedule of its own"
        )
    change_at, before, after = skipped
    old = _zone.wall(change_at // 1000 + before, "UTC")
    new = _zone.wall(change_at // 1000 + after, "UTC")
    assert due is not None
    raise ScheduleError(
        f"{where} is due at a time that does not exist in {zone} on {old[0]:04d}-{old[1]:02d}-{old[2]:02d}, when clocks "
        f"go forward from {old[3]:02d}:{old[4]:02d} to {new[3]:02d}:{new[4]:02d}. "
        f"{scheduler} skips that run and CronWatch would expect it at {_stamp(due, zone)}, so it would be "
        "reported missed. Move the time outside the change, give the schedule a zone without daylight "
        "saving (such as UTC), or give the job a schedule of its own"
    )
