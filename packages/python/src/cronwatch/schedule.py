"""Schedules: "0 2 * * *" (cron, five or six fields), "@hourly", or "every
5m". Due times, deadlines and what a run covers, as schedule.ts has them.
Fire times come from the port of croner in _cron.py, so a Node, a Ruby and a
Python process sharing one store agree on every due time."""

from __future__ import annotations

import re
import threading
from dataclasses import dataclass, field
from typing import Any

from . import _js, _zone
from ._cron import Cron, CronError
from .duration import parse_duration

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


def _fire_after(parsed: ParsedSchedule, start: int) -> int | None:
    """The first fire strictly after `start`, or None when the cron never fires
    again. Croner answers with times in the past when asked from inside the
    hour that repeats when clocks go back, so its answers are filtered, and a
    stretch of nothing but past times is stepped over an hour at a time."""
    cron = parsed._cron
    if cron is None:
        raise ValueError(f'schedule "{parsed.source}" was not made by parse_schedule')
    probe = start
    for _ in range(4):
        runs = cron.next_runs(8, probe)
        if not runs:
            return None
        for fire in runs:
            if fire > start:
                return fire
        probe += 3_600_000
    return None


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
    """The first fire that a run starting at `started_at` does not cover."""
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
