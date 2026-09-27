"""Durations: "15m", "1h30m", "90s", "2d", a number of milliseconds, or a
datetime.timedelta. Parsed and formatted as the SDK's duration.ts does."""

from __future__ import annotations

import re
from datetime import timedelta
from typing import Any, Union

from . import _js

Duration = Union[str, int, float, timedelta]

UNIT_MS = {"ms": 1, "s": 1000, "m": 60_000, "h": 3_600_000, "d": 86_400_000, "w": 604_800_000}
_PART = re.compile(f"([0-9]+(?:\\.[0-9]+)?)[{_js.WHITESPACE}]*(ms|s|m|h|d|w)")


def _not_a_duration(label: str, value: Any) -> ValueError:
    return ValueError(f'{label} "{value}" is not a duration like "15m", "1h30m" or "90s"')


def parse_duration(value: Duration, label: str = "duration") -> int | float:
    """ "15m" -> 900000. Accepts a plain number of milliseconds, a timedelta, and
    compound strings such as "1h30m". Whitespace between parts is fine."""
    if isinstance(value, timedelta):
        return _js.js_round(value.total_seconds() * 1000)
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if not _js.is_finite(value) or value < 0:
            raise ValueError(f"{label} must be a non-negative number of milliseconds")
        return value
    if not isinstance(value, str):
        raise _not_a_duration(label, value)
    text = _js.trim(value).lower()
    if text == "":
        raise ValueError(f"{label} is empty")
    total = 0.0
    consumed = []
    for match in _PART.finditer(text):
        total += float(match.group(1)) * UNIT_MS[match.group(2)]
        consumed.append(match.group(0))
    if _js.SPACES.sub("", "".join(consumed)) != _js.SPACES.sub("", text):
        raise _not_a_duration(label, value)
    return _js.js_round(total)


def format_duration(ms: float) -> str:
    """90000 -> "1m 30s". For messages, not for parsing back."""
    if not _js.is_finite(ms):
        return "?"
    if ms < 1000:
        return f"{_js.number(_js.js_round(ms))}ms"
    parts: list[str] = []
    rest = _js.js_round(ms / 1000)
    for unit, size in (("d", 86_400), ("h", 3_600), ("m", 60), ("s", 1)):
        if rest >= size:
            n = rest // size
            rest -= n * size
            parts.append(f"{n}{unit}")
        if len(parts) == 2:
            break
    return " ".join(parts) or "0s"


def format_relative(at: int, now: int) -> str:
    """ "5m ago", "in 2h". Relative to `now`."""
    diff = at - now
    if abs(diff) < 5_000:
        return "now"
    text = format_duration(abs(diff))
    return f"{text} ago" if diff < 0 else f"in {text}"
