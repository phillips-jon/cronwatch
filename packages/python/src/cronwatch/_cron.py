"""A port of croner 10 (the cron library the SDK uses): its reading of a cron
expression (CronPattern, with its checks and messages) and its walk to the
next matching time (CronDate), including its habits: a day the month does
not have rolls over, a wall-clock time in a spring-forward gap moves forward
by the gap, and a time that happens twice is the earlier one. The names and
the order of every step follow croner's source, so the two agree on every
fire time."""

from __future__ import annotations

import math
import re
from typing import Any

from . import _js, _zone

__all__ = ["ANY", "Cron", "CronDate", "CronError", "CronPattern", "DAYS_IN_MONTH", "LAST", "NTH", "ORDER", "last_day_of_month"]

# Croner's bits for "the nth weekday of the month"; 32 is the last one, 63 any.
NTH = [1, 2, 4, 8, 16]
LAST = 32
ANY = 63

DAYS_IN_MONTH = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
# [field, the field above it, offset from a field value to its pattern index]
ORDER = [("month", "year", 0), ("day", "month", -1), ("hour", "day", 0), ("minute", "hour", 0), ("second", "minute", 0)]

_MONTHS = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
_DAYS = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
_ISO_DATE = re.compile(r"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}", re.ASCII)


class CronError(ValueError):
    """What croner throws for an expression it will not read, with its message."""


def _parse_int(text: str) -> int | None:
    """parseInt(text, 10): None for NaN."""
    match = re.match(f"[{_js.WHITESPACE}]*([+-]?[0-9]+)", text)
    return int(match.group(1)) if match else None


def _to_number(text: str) -> float:
    """JavaScript's Number(text), for the characters a field may hold. NaN when it is not a number."""
    stripped = _js.trim(text)
    if stripped == "":
        return 0.0
    if re.fullmatch(r"[+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?", stripped):
        return float(stripped)
    return math.nan


def _weekday(year: int, month: int, day: int) -> int:
    """new Date(Date.UTC(year, month, day)).getUTCDay(), month 0 based and free to overflow. 0 is Sunday."""
    return (_js.date_utc(year, month, day) // 86_400_000 + 4) % 7


class CronPattern:
    """Croner's CronPattern: the fields of an expression as tables of what matches."""

    def __init__(self, pattern: str) -> None:
        self.pattern = pattern
        self.second = [0] * 60
        self.minute = [0] * 60
        self.hour = [0] * 24
        self.day = [0] * 31
        self.month = [0] * 12
        self.dayOfWeek = [0] * 7
        self.year = [0] * 10_000
        self.lastDayOfMonth = False
        self.lastWeekday = False
        self.nearestWeekdays = [0] * 31
        self.starDOM = False
        self.starDOW = False
        self.starYear = False
        self.useAndLogic = False
        self._parse()

    def _parse(self) -> None:
        if "@" in self.pattern:
            self.pattern = _js.trim(self._nicknames(self.pattern))
        parts = _js.NOT_SPACES.findall(self.pattern) or [""]
        if len(parts) < 5 or len(parts) > 7:
            raise CronError(
                f"CronPattern: invalid configuration format ('{self.pattern}'), exactly five, six, or seven space separated parts are required."
            )
        if len(parts) == 5:
            parts.insert(0, "0")
        if len(parts) == 6:
            parts.append("*")
        if parts[3].upper() == "LW":
            self.lastWeekday = True
            parts[3] = ""
        elif "L" in parts[3].upper():
            parts[3] = re.sub("L", "", parts[3], flags=re.IGNORECASE | re.ASCII)
            self.lastDayOfMonth = True
        if parts[3] == "*":
            self.starDOM = True
        if parts[6] == "*":
            self.starYear = True
        if _js.length16(parts[4]) >= 3:
            parts[4] = self._alpha_months(parts[4])
        if _js.length16(parts[5]) >= 3:
            parts[5] = self._alpha_days(parts[5])
        if parts[5].startswith("+"):
            self.useAndLogic = True
            parts[5] = parts[5][1:]
            if parts[5] == "":
                raise CronError("CronPattern: Day-of-week field cannot be empty after '+' modifier.")
        if parts[5] == "*":
            self.starDOW = True
        if "?" in self.pattern:
            parts = [p.replace("?", "*") for p in parts]
        self._illegal_characters(parts)
        self._part("second", parts[0], 0, 1)
        self._part("minute", parts[1], 0, 1)
        self._part("hour", parts[2], 0, 1)
        self._part("day", parts[3], -1, 1)
        self._part("month", parts[4], -1, 1)
        self._part("dayOfWeek", parts[5], 0, ANY)
        self._part("year", parts[6], 0, 1)

    @staticmethod
    def _nicknames(pattern: str) -> str:
        text = _js.trim(pattern).lower()
        if text in ("@yearly", "@annually"):
            return "0 0 1 1 *"
        if text == "@monthly":
            return "0 0 1 * *"
        if text == "@weekly":
            return "0 0 * * 0"
        if text in ("@daily", "@midnight"):
            return "0 0 * * *"
        if text == "@hourly":
            return "0 * * * *"
        if text == "@reboot":
            raise CronError(
                "CronPattern: @reboot is not supported in this environment. This is an event-based trigger that requires system startup detection."
            )
        return pattern

    @staticmethod
    def _alpha_months(text: str) -> str:
        for i, name in enumerate(_MONTHS):
            text = re.sub(name, str(i + 1), text, flags=re.IGNORECASE | re.ASCII)
        return text

    @staticmethod
    def _alpha_days(text: str) -> str:
        text = re.sub("-sun", "-7", text, flags=re.IGNORECASE | re.ASCII)
        for i, name in enumerate(_DAYS):
            text = re.sub(name, str(i), text, flags=re.IGNORECASE | re.ASCII)
        return text

    @staticmethod
    def _illegal_characters(parts: list[str]) -> None:
        for i, part in enumerate(parts):
            illegal = r"[^/*0-9,\-WwLl]+" if i == 3 else r"[^/*0-9,\-#Ll]+" if i == 5 else r"[^/*0-9,\-]+"
            if re.search(illegal, part):
                raise CronError(f"CronPattern: configuration entry {i} ({part}) contains illegal characters.")

    def _table(self, kind: str) -> list[Any]:
        return getattr(self, kind)

    def _part(self, kind: str, text: str, offset: int, value: Any) -> None:
        table = self._table(kind)
        last_dom = kind == "day" and self.lastDayOfMonth
        last_wd = kind == "day" and self.lastWeekday
        if text == "" and not last_dom and not last_wd:
            raise CronError(f"CronPattern: configuration entry {kind} ({text}) is empty, check for trailing spaces.")
        if text == "*":
            for i in range(len(table)):
                table[i] = value
            return
        items = text.split(",")
        if len(items) > 1:
            for item in items:
                self._part(kind, item, offset, value)
        elif "-" in text and "/" in text:
            self._range_with_stepping(text, kind, offset, value)
        elif "-" in text:
            self._range(text, kind, offset, value)
        elif "/" in text:
            self._stepping(text, kind, offset, value)
        elif text != "":
            self._number(text, kind, offset, value)

    def _number(self, text: str, kind: str, offset: int, value: Any) -> None:
        nth = self._extract_nth(text, kind)
        nearest = "W" in text.upper()
        if kind != "day" and nearest:
            raise CronError("CronPattern: Nearest weekday modifier (W) only allowed in day-of-month.")
        if nearest:
            kind = "nearestWeekdays"
        n = _parse_int(nth[0])
        if n is None:
            raise CronError(f"CronPattern: {kind} is not a number: '{text}'")
        self._set(kind, n + offset, nth[1] or value)

    def _set(self, kind: str, at: int, value: Any) -> None:
        if kind == "dayOfWeek":
            if at == 7:
                at = 0
            if at < 0 or at > 6:
                raise CronError(f"CronPattern: Invalid value for dayOfWeek: {at}")
            self._nth_weekday(at, value)
            return
        if kind in ("second", "minute"):
            limit_ok = 0 <= at < 60
        elif kind == "hour":
            limit_ok = 0 <= at < 24
        elif kind in ("day", "nearestWeekdays"):
            limit_ok = 0 <= at < 31
        elif kind == "month":
            limit_ok = 0 <= at < 12
        elif kind == "year":
            if at < 1 or at >= 10_000:
                raise CronError(f"CronPattern: Invalid value for {kind}: {at} (supported range: 1-9999)")
            limit_ok = True
        else:
            limit_ok = True
        if not limit_ok:
            raise CronError(f"CronPattern: Invalid value for {kind}: {at}")
        self._table(kind)[at] = value

    @staticmethod
    def _validate_range(low: int, high: int, step: int | None, size: int, text: str) -> None:
        if low > high:
            raise CronError(f"CronPattern: From value is larger than to value: '{text}'")
        if step is not None:
            if step == 0:
                raise CronError("CronPattern: Syntax error, illegal stepping: 0")
            if step > size:
                raise CronError(f"CronPattern: Syntax error, steps cannot be greater than maximum value of part ({size})")

    def _range_with_stepping(self, text: str, kind: str, offset: int, value: Any) -> None:
        if "W" in text.upper():
            raise CronError("CronPattern: Syntax error, W is not allowed in ranges with stepping.")
        nth = self._extract_nth(text, kind)
        match = re.fullmatch(r"([0-9]+)-([0-9]+)/([0-9]+)", nth[0])
        if match is None:
            raise CronError(f"CronPattern: Syntax error, illegal range with stepping: '{text}'")
        low = int(match.group(1)) + offset
        high = int(match.group(2)) + offset
        step = int(match.group(3))
        self._validate_range(low, high, step, len(self._table(kind)), text)
        for at in range(low, high + 1, step):
            self._set(kind, at, nth[1] or value)

    def _extract_nth(self, text: str, kind: str) -> tuple[str, str | None]:
        if "#" in text:
            if kind != "dayOfWeek":
                raise CronError("CronPattern: nth (#) only allowed in day-of-week field")
            pieces = text.split("#")
            return pieces[0], pieces[1]
        if text.upper().endswith("L"):
            if kind != "dayOfWeek":
                raise CronError("CronPattern: L modifier only allowed in day-of-week field (use L alone for day-of-month)")
            return text[:-1], "L"
        return text, None

    def _range(self, text: str, kind: str, offset: int, value: Any) -> None:
        if "W" in text.upper():
            raise CronError("CronPattern: Syntax error, W is not allowed in a range.")
        nth = self._extract_nth(text, kind)
        bounds = nth[0].split("-")
        if len(bounds) != 2:
            raise CronError(f"CronPattern: Syntax error, illegal range: '{text}'")
        low = _parse_int(bounds[0])
        high = _parse_int(bounds[1])
        if low is None:
            raise CronError("CronPattern: Syntax error, illegal lower range (NaN)")
        if high is None:
            raise CronError("CronPattern: Syntax error, illegal upper range (NaN)")
        low += offset
        high += offset
        self._validate_range(low, high, None, len(self._table(kind)), text)
        for at in range(low, high + 1):
            self._set(kind, at, nth[1] or value)

    def _stepping(self, text: str, kind: str, _offset: int, value: Any) -> None:
        if "W" in text.upper():
            raise CronError("CronPattern: Syntax error, W is not allowed in parts with stepping.")
        nth = self._extract_nth(text, kind)
        parts = nth[0].split("/")
        if len(parts) != 2:
            raise CronError(f"CronPattern: Syntax error, illegal stepping: '{text}'")
        if parts[0] == "":
            raise CronError(
                f"CronPattern: Syntax error, stepping with missing prefix ('{text}') is not allowed. Use wildcard (*/step) or range (min-max/step) instead."
            )
        if parts[0] != "*":
            raise CronError(
                f"CronPattern: Syntax error, stepping with numeric prefix ('{text}') is not allowed. Use wildcard (*/step) or range (min-max/step) instead."
            )
        step = _parse_int(parts[1])
        if step is None:
            raise CronError("CronPattern: Syntax error, illegal stepping: (NaN)")
        size = len(self._table(kind))
        self._validate_range(0, size - 1, step, size, text)
        for at in range(0, size, step) if step > 0 else ():
            self._set(kind, at, nth[1] or value)

    def _nth_weekday(self, day: int, nth: Any) -> None:
        if isinstance(nth, str) and nth.upper() == "L":
            self.dayOfWeek[day] |= LAST
            return
        if nth == ANY and not isinstance(nth, str):
            self.dayOfWeek[day] = ANY
            return
        n = _to_number(nth) if isinstance(nth, str) else float(nth)
        if n < 6 and n > 0:
            index = n - 1
            if index == int(index) and 0 <= int(index) < len(NTH):
                self.dayOfWeek[day] |= NTH[int(index)]
            return
        kind = "string" if isinstance(nth, str) else "number"
        shown = nth if isinstance(nth, str) else _js.number(nth)
        raise CronError(f"CronPattern: nth weekday out of range, should be 1-5 or L. Value: {shown}, Type: {kind}")


def last_day_of_month(year: int, month: int) -> int | None:
    """Croner's getLastDayOfMonth, month 0 based."""
    if month != 1:
        return DAYS_IN_MONTH[month] if 0 <= month < 12 else None
    wall = _js.date_utc(year, month + 1, 0)
    return _js.civil_from_days(wall // 86_400_000)[2]


class CronDate:
    """Croner's CronDate: a wall-clock time whose fields are moved forward to
    the next match, a field at a time, spilling into the next month or year
    as croner does. Month is 0 based."""

    __slots__ = ("tz", "year", "month", "day", "hour", "minute", "second", "ms")

    def __init__(self, tz: str | None) -> None:
        self.tz = tz
        self.year = self.month = self.day = self.hour = self.minute = self.second = self.ms = 0

    @classmethod
    def from_ms(cls, at: int, tz: str | None) -> CronDate:
        """new CronDate(new Date(at), tz)."""
        date = cls(tz)
        sec = math.floor(at / 1000)
        year, month, day, hour, minute, second = _zone.wall(sec, tz)
        date.year, date.month, date.day = year, month - 1, day
        date.hour, date.minute, date.second = hour, minute, second
        date.ms = int(at - sec * 1000)
        return date

    def copy(self) -> CronDate:
        other = CronDate(self.tz)
        for name in CronDate.__slots__:
            setattr(other, name, getattr(self, name))
        return other

    def apply(self) -> bool:
        m = self.month
        if (
            m > 11
            or m < 0
            or self.day > DAYS_IN_MONTH[m]
            or self.day < 1
            or self.hour > 59
            or self.minute > 59
            or self.second > 59
            or self.hour < 0
            or self.minute < 0
            or self.second < 0
        ):
            at = _js.date_utc(self.year, self.month, self.day, self.hour, self.minute, self.second, self.ms)
            sec, self.ms = divmod(at, 1000)
            days, rest = divmod(sec, 86_400)
            year, month, day = _js.civil_from_days(days)
            self.year, self.month, self.day = year, month - 1, day
            self.hour, rest = divmod(rest, 3600)
            self.minute, self.second = divmod(rest, 60)
            return True
        return False

    def _last_weekday(self, year: int, month: int) -> int:
        last = last_day_of_month(year, month) or 0
        wd = _weekday(year, month, last)
        return last - 2 if wd == 0 else last - 1 if wd == 6 else last

    def _nearest_weekday(self, year: int, month: int, day: int) -> int:
        last = last_day_of_month(year, month)
        if last is not None and day > last:
            return -1
        wd = _weekday(year, month, day)
        if wd == 0:
            return day - 2 if day == last else day + 1
        if wd == 6:
            return day + 2 if day == 1 else day - 1
        return day

    def _is_nth_weekday(self, year: int, month: int, day: int, bits: int) -> bool:
        wd = _weekday(year, month, day)
        count = sum(1 for d in range(1, day + 1) if _weekday(year, month, d) == wd)
        if bits & ANY and 1 <= count <= len(NTH) and NTH[count - 1] & bits:
            return True
        if bits & LAST:
            last = last_day_of_month(year, month) or 0
            return all(_weekday(year, month, d) != wd for d in range(day + 1, last + 1))
        return False

    def _find_next(self, pattern: CronPattern, kind: str, offset: int) -> int:
        """1: the field already matches, 2: moved forward to a match, 3: none left."""
        before = getattr(self, kind)
        table = pattern._table(kind)
        last = last_day_of_month(self.year, self.month) if pattern.lastDayOfMonth else None
        first_weekday = _weekday(self.year, self.month, 1) if not pattern.starDOW and kind == "day" else 0
        u = before + offset
        while u < len(table):
            d: Any = table[u] if u >= 0 else None
            if kind == "day" and not d:
                for c, nearest in enumerate(pattern.nearestWeekdays):
                    if nearest:
                        m = self._nearest_weekday(self.year, self.month, c - offset)
                        if m == -1:
                            continue
                        if m == u - offset:
                            d = 1
                            break
            if kind == "day" and pattern.lastWeekday:
                if u - offset == self._last_weekday(self.year, self.month):
                    d = 1
            if kind == "day" and pattern.lastDayOfMonth and u - offset == last:
                d = 1
            if kind == "day" and not pattern.starDOW:
                c_bits = pattern.dayOfWeek[(first_weekday + (u - offset - 1)) % 7]
                if c_bits and c_bits & ANY:
                    c_bits = 1 if self._is_nth_weekday(self.year, self.month, u - offset, c_bits) else 0
                elif c_bits:
                    raise CronError(f"CronDate: Invalid value for dayOfWeek encountered. {c_bits}")
                if pattern.useAndLogic:
                    d = d and c_bits
                elif not pattern.starDOM:
                    d = d or c_bits
                else:
                    d = d and c_bits
            if d:
                setattr(self, kind, u - offset)
                return 2 if before != getattr(self, kind) else 1
            u += 1
        return 3

    def _recurse(self, pattern: CronPattern) -> CronDate | None:
        level = 0
        while True:
            if level == 0 and not pattern.starYear:
                if 0 <= self.year < len(pattern.year) and pattern.year[self.year] == 0:
                    found = -1
                    for y in range(self.year + 1, min(len(pattern.year), 10_000)):
                        if pattern.year[y] == 1:
                            found = y
                            break
                    if found == -1:
                        return None
                    self.year, self.month, self.day = found, 0, 1
                    self.hour = self.minute = self.second = self.ms = 0
                if self.year >= 10_000:
                    return None
            kind, above, offset = ORDER[level]
            n = self._find_next(pattern, kind, offset)
            if n > 1:
                for i in range(level + 1, len(ORDER)):
                    setattr(self, ORDER[i][0], -ORDER[i][2])
                if n == 3:
                    setattr(self, above, getattr(self, above) + 1)
                    setattr(self, kind, -offset)
                    self.apply()
                    if level == 0 and not pattern.starYear:
                        while 0 <= self.year < len(pattern.year) and pattern.year[self.year] == 0 and self.year < 10_000:
                            self.year += 1
                        if self.year >= 10_000 or self.year >= len(pattern.year):
                            return None
                    level = 0
                    continue
                if self.apply():
                    level -= 1
                    continue
            level += 1
            if level >= len(ORDER):
                return self
            if (self.year >= 3000) if pattern.starYear else (self.year >= 10_000):
                return None

    def increment(self, pattern: CronPattern) -> CronDate | None:
        self.second += 1
        self.ms = 0
        self.apply()
        return self._recurse(pattern)

    def time_ms(self) -> int:
        """getDate(false).getTime(): the instant this wall-clock time names."""
        wall = (self.year, self.month + 1, self.day, self.hour, self.minute, self.second)
        return _zone.to_utc(wall, self.tz) * 1000


class Cron:
    """What schedule.py uses of croner's Cron: an expression that schedules
    nothing and only answers nextRuns."""

    def __init__(self, text: str, timezone: str | None = None) -> None:
        if text and ":" in text[1:]:
            # Croner reads a string with a colon after its first character as a
            # one-time date to fire at, not as a cron expression.
            if _ISO_DATE.match(text):
                raise CronError("CronPattern: a one-time date is not supported")
            raise CronError("Invalid ISO8601 passed to timezone parser.")
        self.timezone = timezone or None
        self.pattern = CronPattern(text)

    def next_runs(self, count: int, start: int) -> list[int]:
        """Up to `count` fires after `start` (epoch ms), each found from the one before, as nextRuns."""
        runs: list[int] = []
        previous = CronDate.from_ms(start, self.timezone)
        for _ in range(count):
            found = previous.copy().increment(self.pattern)
            if found is None:
                break
            runs.append(found.time_ms())
            previous = found
        return runs
