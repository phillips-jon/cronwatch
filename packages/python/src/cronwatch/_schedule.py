"""Schedules: "0 2 * * *" (cron, five or six fields), "@hourly", or "every
5m". Due times, deadlines, and what a run covers, as schedule.ts has them.
Fire times come from the port of croner in _cron.py, so a Node, a Ruby, and a
Python process sharing one store agree on every due time."""

from __future__ import annotations

import re
import threading
from dataclasses import dataclass, field
from typing import Any

from . import _js, _zone
from ._cron import Cron, CronError
from ._duration import FIRST_DATE_MS, LAST_DATE_MS, parse_duration

__all__ = [
    "CYCLE_MS",
    "EARLY_SLACK_MS",
    "Expectation",
    "ParsedSchedule",
    "expectation",
    "fires_between",
    "next_fire",
    "parse_schedule",
    "run_covers",
]

#: How early a run may start and still count for the fire it was meant for.
EARLY_SLACK_MS = 60_000

_EVERY = re.compile(f"every[{_js.WHITESPACE}]+([^\\n\\r\\u2028\\u2029]+)\\Z", re.IGNORECASE | re.ASCII)


@dataclass(frozen=True)
class ParsedSchedule:
    kind: str
    source: str
    #: The IANA timezone a cron is read in, when one was given.
    timezone: str | None = None
    #: For intervals, the period in milliseconds.
    every_ms: float | None = None
    _cron: Cron | None = field(default=None, repr=False, compare=False)

    @property
    def is_cron(self) -> bool:
        return self.kind == "cron"

    @property
    def is_interval(self) -> bool:
        return self.kind == "interval"

    def to_dict(self) -> dict[str, Any]:
        out: dict[str, Any] = {"kind": self.kind, "source": self.source}
        if self.timezone:
            out["timezone"] = self.timezone
        if self.every_ms is not None:
            out["everyMs"] = self.every_ms
        return out


@dataclass(frozen=True)
class Expectation:
    #: When the next run the schedule asks for is due.
    due_at: int
    #: Missed once now passes this.
    deadline: int

    def to_dict(self) -> dict[str, Any]:
        return {"dueAt": self.due_at, "deadline": self.deadline}


_cache: dict[str, ParsedSchedule] = {}
_cache_lock = threading.Lock()


def parse_schedule(schedule: str, timezone: str | None = None) -> ParsedSchedule:
    """Parsed once per (schedule, timezone) pair and cached. Without a timezone
    the expression is read in the process timezone, like crontab. Vercel and
    GitHub Actions run their crons in UTC, so pass timezone="UTC" for those."""
    key = f"{timezone or ''}|{schedule}"
    with _cache_lock:
        hit = _cache.get(key)
    if hit is not None:
        return hit
    text = _js.trim(schedule)
    every = _EVERY.match(text)
    if every:
        every_ms = parse_duration(every.group(1), "schedule interval")
        if every_ms < 1000:
            raise ValueError(f'schedule "{schedule}" is shorter than one second')
        parsed = ParsedSchedule(kind="interval", source=text, every_ms=every_ms)
    else:
        try:
            cron = Cron(text, timezone or None)
        except CronError as error:
            raise ValueError(f'schedule "{schedule}" is not a cron expression or "every <duration>": {error}') from None
        parsed = ParsedSchedule(kind="cron", source=text, timezone=timezone or None, _cron=cron)
    with _cache_lock:
        _cache[key] = parsed
    return parsed


#: Four hundred Gregorian years: 146,097 days, a whole number of weeks, after
#: which the calendar repeats date for date and weekday for weekday.
CYCLE_MS = 146_097 * 86_400_000
#: Times before the year 400 are asked a cycle or more later, as the SDK asks
#: croner (which misreads a year below 100).
_CRONER_FIRST_MS = _js.date_utc(400, 0, 1)
#: Times from the year 2800 are asked a cycle or more earlier, as the SDK asks
#: croner (which finds no fire past the year 3000, and nor does its port).
_CRONER_LAST_MS = _js.date_utc(2800, 0, 1)


def _runs_after(cron: Cron, count: int, start: int) -> list[int]:
    """The next `count` fires of a cron strictly after `start`, which lies
    within the years 1 to 9999, dropping any after 9999. A time outside the
    years 400 to 2800 is moved by whole 400-year cycles into them, and its
    fires moved back: a time before 400 goes forward, into the same local
    mean time every zone kept then, and one from 2800 goes back, to where the
    zone's present rules already hold."""
    shift = 0
    if start < _CRONER_FIRST_MS:
        shift = -((start - _CRONER_FIRST_MS) // CYCLE_MS) * CYCLE_MS
    elif start >= _CRONER_LAST_MS:
        shift = -((start - _CRONER_LAST_MS) // CYCLE_MS + 1) * CYCLE_MS
    out: list[int] = []
    for fire in cron.next_runs(count, start + shift):
        t = fire - shift
        if t > LAST_DATE_MS:
            break
        out.append(t)
    return out


def _count_from(start: int) -> int | None:
    """A stored time as a cron's fires are counted from it. A start read from
    a foreign or damaged row can be any number: one before the year 1 counts
    from just before its first millisecond, so the first fire of the year 1
    is the next one, and one at or after the last millisecond of 9999 has no
    fire after it at all (None). No fire is ever after 9999."""
    if start >= LAST_DATE_MS:
        return None
    return start if start >= FIRST_DATE_MS else FIRST_DATE_MS - 1


def _fire_after(parsed: ParsedSchedule, start: int) -> int | None:
    """The first fire strictly after `start`, or None when the cron never fires
    again. Croner answers with times in the past when asked from inside the
    hour that repeats when clocks go back, so its answers are filtered, and a
    stretch of nothing but past times is stepped over an hour at a time."""
    cron = parsed._cron
    if cron is None:
        raise ValueError(f'schedule "{parsed.source}" was not made by parse_schedule')
    counted = _count_from(start)
    if counted is None:
        return None
    probe = counted
    for _ in range(4):
        runs = _runs_after(cron, 8, probe)
        if not runs:
            return None
        for fire in runs:
            if fire > counted:
                return fire
        probe += 3_600_000
    return None


def fires_between(parsed: ParsedSchedule, start: int, end: int, limit: int) -> list[int] | None:
    """Every fire of a cron strictly after `start` and at or before `end`,
    ascending, or None when there are more than `limit`. Asks for fires in
    batches, which is far cheaper than one next_fire per fire, and drops any
    that do not move forward (see _fire_after). The dashboard's timelines draw these."""
    cron = parsed._cron
    if cron is None:
        raise ValueError(f'schedule "{parsed.source}" was not made by parse_schedule')
    out: list[int] = []
    counted = _count_from(start)
    if counted is None:
        return out
    probe = counted
    last = counted
    for _ in range(1000):
        batch = _runs_after(cron, min(limit + 1 - len(out), 24), probe)
        if not batch:
            return out
        for t in batch:
            if t <= last:
                continue
            if t > end:
                return out
            out.append(t)
            last = t
            if len(out) > limit:
                return None
        finish = batch[-1]
        probe = finish if finish > probe else probe + 3_600_000
    return out


def next_fire(parsed: ParsedSchedule, start: int, last_run_at: int | None) -> int | None:
    """The next time the schedule fires strictly after `start`. For an interval, counted from the last run when there is one."""
    if parsed.kind == "interval":
        base = start if last_run_at is None else last_run_at
        return base + parsed.every_ms  # type: ignore[operator, return-value]
    return _fire_after(parsed, start)


def expectation(parsed: ParsedSchedule, last_run_at: int | None, registered_at: int, grace_ms: float) -> Expectation | None:
    """When the schedule next wants a run, given the last one. For a cron that
    is the first fire the last run does not already cover; with no run yet,
    the first fire at or after registration. For an interval it is the last
    run's start (or registration) plus the interval. None for a cron that
    never fires again.

    Counting forward from the last run, rather than back from now, is what
    lets a job whose period is shorter than its grace be missed at all, and it
    works for a cron that fires once a year or less."""
    if parsed.kind == "interval":
        due_at: float | None = (registered_at if last_run_at is None else last_run_at) + parsed.every_ms  # type: ignore[operator]
    elif last_run_at is None:
        due_at = _fire_after(parsed, registered_at - 1)
    else:
        due_at = _due_after_run(parsed, last_run_at)
    return None if due_at is None else Expectation(due_at=due_at, deadline=due_at + grace_ms)  # type: ignore[arg-type]


def _due_after_run(parsed: ParsedSchedule, started_at: int) -> int | None:
    """The first fire that a run starting at `started_at` does not cover. A
    start before the year 1 covers none of them, so the first fire of the
    year 1 is due; after 9999 there is none (see _count_from)."""
    # A fire at or before the start is covered by the run itself.
    upcoming = _fire_after(parsed, started_at)
    if upcoming is None:
        return None
    following = _fire_after(parsed, upcoming)
    covers = run_covers(started_at, upcoming, following) or _in_spring_forward_gap(parsed, started_at, upcoming)
    return following if covers else upcoming


def run_covers(started_at: int, due_at: int, following_at: int | None = None) -> bool:
    """Whether a run starting at `started_at` covers the fire at `due_at`. A
    minute of slack before the tick absorbs schedulers that fire a touch
    early. When the fire after `due_at` is known, the slack is at most half
    the gap between the two, so one run of an every-minute cron never covers
    two fires."""
    slack = EARLY_SLACK_MS if following_at is None else min(EARLY_SLACK_MS, (following_at - due_at) // 2)
    return started_at >= due_at - slack


def _in_spring_forward_gap(parsed: ParsedSchedule, started_at: int, fire_at: int) -> bool:
    """On the night clocks spring forward, a fire whose local time does not
    exist (02:30 when 02:00 jumps to 03:00) is moved by croner to the same
    distance past the jump (03:30), while vixie cron runs it at the jump
    itself (03:00). A run that starts at or after the jump, and before the
    first fire after it when that fire lies within one gap of it, is taken to
    cover that fire, so neither scheduler's run is reported as missed."""
    lookback = 3 * 3_600_000
    # Every zone kept its local mean time, with no clock change, in the year 1.
    if fire_at - lookback < FIRST_DATE_MS:
        return False
    after = _utc_offset(fire_at, parsed.timezone)
    before = _utc_offset(fire_at - lookback, parsed.timezone)
    gap = after - before
    if gap <= 0:
        return False
    # Find the jump: the first minute in the window with the later offset.
    lo = fire_at - lookback
    hi = fire_at
    while hi - lo > 60_000:
        mid = lo + (hi - lo) // 2
        if _utc_offset(mid, parsed.timezone) == after:
            hi = mid
        else:
            lo = mid
    jump_at = (hi // 60_000) * 60_000
    if fire_at - jump_at >= gap or started_at < jump_at - EARLY_SLACK_MS or started_at >= fire_at:
        return False
    # Only the first fire after the jump can be a moved one; a cron that also
    # fires at the jump (every 10 minutes, say) was not moved at all.
    return _fire_after(parsed, jump_at - 1) == fire_at


def _utc_offset(at: int, timezone: str | None) -> int:
    """Milliseconds the zone's wall clock is ahead of UTC at `at`."""
    return _zone.offset(at // 1000, timezone) * 1000
