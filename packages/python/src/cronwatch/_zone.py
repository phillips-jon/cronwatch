"""IANA zones through the standard library's zoneinfo, or the process's own
zone when none is named, as JavaScript's Date does; and croner's wall-clock
arithmetic on them."""

from __future__ import annotations

import threading
import time
from datetime import datetime, timezone as _utc_zone
from functools import lru_cache
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError, available_timezones

from . import _js

_lock = threading.Lock()
_names: dict[str, str] | None = None

Wall = tuple[int, int, int, int, int, int]


def _canonical(name: str) -> str | None:
    """The zone's name as zoneinfo spells it. Names are matched without regard to case, as Intl does."""
    global _names
    with _lock:
        if _names is None:
            _names = {n.lower(): n for n in available_timezones()}
            _names.setdefault("utc", "UTC")
        return _names.get(name.lower())


@lru_cache(maxsize=512)
def get(name: str) -> ZoneInfo:
    """A zone by its IANA name. Raises ValueError for anything else."""
    if not isinstance(name, str) or name == "" or "\x00" in name:
        raise ValueError(f'timezone "{name}" is not an IANA timezone')
    try:
        return ZoneInfo(name)
    except (ZoneInfoNotFoundError, ValueError, OSError):
        canonical = _canonical(name)
        if canonical is None:
            raise ValueError(f'timezone "{name}" is not an IANA timezone') from None
        try:
            return ZoneInfo(canonical)
        except (ZoneInfoNotFoundError, ValueError, OSError):
            raise ValueError(f'timezone "{name}" is not an IANA timezone') from None


def is_valid(name: object) -> bool:
    if not isinstance(name, str):
        return False
    try:
        get(name)
        return True
    except ValueError:
        return False


#: Four hundred Gregorian years in seconds, after which the calendar, and a
#: zone's rules both long before and long after today, repeat.
_CYCLE_SEC = 146_097 * 86_400
#: The start of the year 2 and of the year 9999: outside them a local time
#: could fall outside datetime's years 1 to 9999.
_SAFE_FIRST_SEC = -62_104_060_800
_SAFE_LAST_SEC = 253_370_764_800


def offset(sec: int, tz: str | None) -> int:
    """Seconds the wall clock is ahead of UTC at epoch second `sec`. A time
    near or past the ends of the years 1 to 9999 is read a 400-year cycle or
    more nearer today, where datetime can hold its local time and the zone
    keeps the same offset."""
    if sec < _SAFE_FIRST_SEC:
        sec += -((sec - _SAFE_FIRST_SEC) // _CYCLE_SEC) * _CYCLE_SEC
    elif sec >= _SAFE_LAST_SEC:
        sec -= ((sec - _SAFE_LAST_SEC) // _CYCLE_SEC + 1) * _CYCLE_SEC
    if tz is None:
        return time.localtime(sec).tm_gmtoff
    moment = datetime.fromtimestamp(sec, tz=_utc_zone.utc).astimezone(get(tz))
    delta = moment.utcoffset()
    return int(delta.total_seconds()) if delta is not None else 0


def wall(sec: int, tz: str | None) -> Wall:
    """The wall clock at epoch second `sec`: (year, month, day, hour, minute, second), month 1 to 12."""
    local = sec + offset(sec, tz)
    days, rest = divmod(local, 86_400)
    year, month, day = _js.civil_from_days(days)
    hour, rest = divmod(rest, 3600)
    minute, second = divmod(rest, 60)
    return (year, month, day, hour, minute, second)


def civil_seconds(w: Wall) -> int:
    """A wall-clock time read as if it were UTC, in epoch seconds (croner's T())."""
    year, month, day, hour, minute, second = w
    return _js.date_utc(year, month - 1, day, hour, minute, second) // 1000


def to_utc(w: Wall, tz: str | None) -> int:
    """Croner's fromTZ: the instant a wall-clock time names, in epoch seconds.
    A time that falls in a spring-forward gap is moved forward by the gap; a
    time that occurs twice (fall back) is the earlier of the two."""
    target = civil_seconds(w)
    guess = target + (target - civil_seconds(wall(target, tz)))
    seen = wall(guess, tz)
    if seen == w:
        earlier = guess - 3600
        return earlier if wall(earlier, tz) == w else guess
    shifted = guess + target - civil_seconds(seen)
    if wall(shifted, tz) == w:
        return shifted
    return max(guess, shifted)
