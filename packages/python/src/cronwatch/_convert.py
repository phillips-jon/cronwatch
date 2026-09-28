"""What the scheduler integrations (cronwatch.celery, cronwatch.apscheduler)
share: cron fields written from the sets of values a scheduler matches, an
interval as CronWatch's "every" text, a zone's IANA name, and the job options
an integration takes. No framework is imported here."""

from __future__ import annotations

import os
from collections.abc import Iterable, Mapping
from datetime import timedelta, tzinfo
from typing import Any

from . import _zone
from ._scheduler_check import ScheduleError
from .types import JobDefinition


def field_text(values: Iterable[int], lo: int, hi: int) -> str:
    """A cron field for a set of values from lo to hi: "*" for all of them,
    "*/n" for a step from lo (three values or more), else a list with runs of three or more as ranges."""
    found = sorted(set(values))
    if found == list(range(lo, hi + 1)):
        return "*"
    for step in range(2, hi - lo + 1):
        if found == list(range(lo, hi + 1, step)) and len(found) > 2:
            return f"*/{step}"
    parts: list[str] = []
    i = 0
    while i < len(found):
        j = i
        while j + 1 < len(found) and found[j + 1] == found[j] + 1:
            j += 1
        if j - i >= 2:
            parts.append(f"{found[i]}-{found[j]}")
        else:
            parts.extend(str(v) for v in found[i : j + 1])
        i = j + 1
    return ",".join(parts)


def every_text(interval: timedelta | float) -> str:
    """ "every 1h30m" for an interval (a timedelta, or seconds), exact to the millisecond."""
    seconds = interval.total_seconds() if isinstance(interval, timedelta) else float(interval)
    ms = round(seconds * 1000)
    parts: list[str] = []
    for unit, size in (("d", 86_400_000), ("h", 3_600_000), ("m", 60_000), ("s", 1000), ("ms", 1)):
        if ms >= size:
            n, ms = divmod(ms, size)
            parts.append(f"{n}{unit}")
    return "every " + ("".join(parts) or "0ms")


def zone_name(tz: Any) -> str | None:
    """The IANA name of a tzinfo (zoneinfo, pytz, dateutil, UTC), or None when it has none."""
    if tz is None:
        return None
    if isinstance(tz, str):
        return tz if _zone.is_valid(tz) else None
    for attribute in ("key", "zone"):
        name = getattr(tz, attribute, None)
        if isinstance(name, str) and _zone.is_valid(name):
            return name
    if isinstance(tz, tzinfo):
        from datetime import timezone

        if tz is timezone.utc or tz == timezone.utc:
            return "UTC"
    text = str(tz)
    return text if _zone.is_valid(text) else None


def local_zone_name() -> str | None:
    """The process's own zone by its IANA name: $TZ, or where /etc/localtime points."""
    name = os.environ.get("TZ", "").lstrip(":")
    if name and _zone.is_valid(name):
        return name
    try:
        target = os.path.realpath("/etc/localtime")
    except OSError:
        return None
    marker = "zoneinfo/"
    if marker in target:
        candidate = target.split(marker, 1)[1]
        if _zone.is_valid(candidate):
            return candidate
    return None


def check_options(options: Mapping[str, Any], where: str, *, allow: Iterable[str] = ()) -> dict[str, Any]:
    """Job options given to an integration: Cronwatch.job()'s, and `allow`'s."""
    known = set(JobDefinition.OPTIONS) | set(allow)
    unknown = [key for key in options if key not in known]
    if unknown:
        raise TypeError(f"{where}: unknown option {', '.join(unknown)}")
    return dict(options)


__all__ = ["ScheduleError", "check_options", "every_text", "field_text", "local_zone_name", "zone_name"]
