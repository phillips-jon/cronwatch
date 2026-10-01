"""The check behind cronwatch.celery's and cronwatch.apscheduler's schedule
conversions (a port of the gem's check_fires), against schedulers made here
that agree with CronWatch, skip a run, or run at other times."""

from __future__ import annotations

from collections.abc import Callable

import pytest

from cronwatch._convert import every_text, field_text, zone_name
from cronwatch._js import date_utc
from cronwatch._scheduler_check import NeverFires, ScheduleError, check_fires, transitions
from cronwatch._schedule import _fire_after, parse_schedule

NOW = date_utc(2026, 0, 5)


def like_cronwatch(text: str, zone: str, skip: Callable[[int], bool] = lambda at: False, shift: int = 0) -> Callable[[int, int | None], list[int]]:
    """A scheduler that fires when CronWatch does, less the fires `skip` names, each moved by `shift`."""
    parsed = parse_schedule(text, zone)

    def runs(start: int, end: int | None) -> list[int]:
        before = None
        for days in (2, 400):
            at = start - days * 86_400_000
            while True:
                fire = _fire_after(parsed, at)
                assert fire is not None
                if fire > start:
                    break
                if not skip(fire):
                    before = fire
                at = fire
            if before is not None:
                break
        out = [before + shift] if before is not None else []
        at = start
        while True:
            fire = _fire_after(parsed, at)
            if fire is None:
                return out
            at = fire
            if skip(fire):
                continue
            out.append(fire + shift)
            if (end is None and len(out) > 8) or (end is not None and fire > end):
                return out

    return runs


def test_a_scheduler_that_agrees_with_cronwatch_passes() -> None:
    for text, zone in [("0 2 * * *", "Europe/London"), ("*/15 * * * *", "America/New_York"), ("0 0 1 * +1", "UTC"), ("30 1 * * *", "Europe/London")]:
        check_fires(like_cronwatch(text, zone), parse_schedule(text, zone), f"cronwatch: {text}", "Test", daily="+" not in text, now_ms=NOW)


def test_a_run_the_scheduler_skips_when_clocks_go_forward_is_refused_with_the_date() -> None:
    parsed = parse_schedule("30 1 * * *", "Europe/London")
    # A vixie-style scheduler that never runs 01:30 on the night 01:00 jumps to 02:00.
    skipped = date_utc(2026, 2, 29, 1, 30)
    with pytest.raises(ScheduleError) as caught:
        check_fires(like_cronwatch("30 1 * * *", "Europe/London", skip=lambda at: at == skipped), parsed, 'cronwatch: entry "x": "30 1 * * *"', "Test", daily=True, now_ms=NOW)
    assert str(caught.value) == (
        'cronwatch: entry "x": "30 1 * * *" is due at a time that does not exist in Europe/London on 2026-03-29, when clocks '
        "go forward from 01:00 to 02:00. Test skips that run and CronWatch would expect it at 2026-03-29 02:30:00, so it would be "
        "reported missed. Move the time outside the change, give the schedule a zone without daylight saving (such as UTC), "
        "or give the job a schedule of its own"
    )


def test_runs_at_other_times_are_refused() -> None:
    parsed = parse_schedule("0 2 * * *", "UTC")
    with pytest.raises(ScheduleError) as caught:
        check_fires(like_cronwatch("0 2 * * *", "UTC", shift=3_600_000), parsed, "cronwatch: x", "Test", daily=True, now_ms=NOW)
    assert str(caught.value).startswith('cronwatch: x is "0 2 * * *" in UTC, but after a run at 2025-12-31 03:00:00 Test runs it next at 2026-01-01 03:00:00')
    assert str(caught.value).endswith("so it cannot be converted exactly; give the job a schedule of its own")


def test_a_schedule_that_never_fires_is_refused() -> None:
    def never(start: int, end: int | None) -> list[int]:
        raise NeverFires("no date matches")

    with pytest.raises(ScheduleError, match="^cronwatch: x never fires: no date matches$"):
        check_fires(never, parse_schedule("0 0 1 1 *", "UTC"), "cronwatch: x", "Test", daily=False, now_ms=NOW)


def test_transitions_and_the_conversion_helpers() -> None:
    changes = transitions("Europe/London", date_utc(2026, 0, 1), date_utc(2027, 0, 1))
    assert changes == [(date_utc(2026, 2, 29, 1), 0, 3600), (date_utc(2026, 9, 25, 1), 3600, 0)]
    assert transitions("UTC", date_utc(2026, 0, 1), date_utc(2027, 0, 1)) == []
    assert field_text(range(60), 0, 59) == "*"
    assert field_text([0, 15, 30, 45], 0, 59) == "*/15"
    assert field_text([1, 2, 3, 5, 9, 10], 0, 59) == "1-3,5,9,10"
    assert field_text([4], 0, 23) == "4"
    assert every_text(90) == "every 1m30s"
    assert every_text(86_400 + 0.5) == "every 1d500ms"
    from datetime import timedelta, timezone
    from zoneinfo import ZoneInfo

    assert every_text(timedelta(hours=2)) == "every 2h"
    assert zone_name(ZoneInfo("Europe/Paris")) == "Europe/Paris"
    assert zone_name(timezone.utc) == "UTC"
    assert zone_name(timezone(timedelta(hours=2))) is None
    assert zone_name("Nowhere/Else") is None
