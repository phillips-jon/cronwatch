"""The few places JavaScript and Python disagree about text and numbers,
settled the JavaScript way.

The SDK writes the stored rows, alert text, and webhook bodies, so this port
reproduces them byte for byte: Math.round, String(number), JSON.stringify
(number formatting, key order, escaping), String.prototype.trim, the \\s
class, and lengths counted in UTF-16 code units.
"""

from __future__ import annotations

import json
import math
import re
from collections.abc import Mapping
from typing import Any

__all__ = [
    "MAX_SAFE_INTEGER",
    "NOT_SPACES",
    "SPACE",
    "SPACES",
    "WHITESPACE",
    "civil_from_days",
    "date_utc",
    "days_from_civil",
    "decimal",
    "dumps",
    "head16",
    "is_finite",
    "is_integer",
    "is_number",
    "iso",
    "js_round",
    "length16",
    "loads",
    "number",
    "object_keys",
    "quote",
    "tail16",
    "to_json_value",
    "trim",
    "trim_end",
    "well_formed",
]

# What JavaScript's \s and trim() treat as whitespace, for use inside a character class.
WHITESPACE = "\\t\\n\\x0b\\x0c\\r \\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000\\ufeff"
SPACE = re.compile(f"[{WHITESPACE}]")
SPACES = re.compile(f"[{WHITESPACE}]+")
NOT_SPACES = re.compile(f"[^{WHITESPACE}]+")
_LEADING = re.compile(f"^[{WHITESPACE}]+")
_TRAILING = re.compile(f"[{WHITESPACE}]+\\Z")

# Number.MAX_SAFE_INTEGER. Past it JavaScript holds an integer as the nearest double.
MAX_SAFE_INTEGER = 2**53 - 1

_ESCAPES = {'"': '\\"', "\\": "\\\\", "\b": "\\b", "\f": "\\f", "\n": "\\n", "\r": "\\r", "\t": "\\t"}
# Control characters, the quote, the backslash, and lone surrogates.
_NEEDS_ESCAPE = re.compile('["\\\\\x00-\x1f\ud800-\udfff]')
# An array index is a canonical integer below 2**32 - 1; JavaScript lists those keys first.
_INDEX_KEY = re.compile(r"(?:0|[1-9][0-9]{0,9})\Z")


def trim(text: str) -> str:
    """String.prototype.trim."""
    return _TRAILING.sub("", _LEADING.sub("", text))


def trim_end(text: str) -> str:
    """String.prototype.trimEnd."""
    return _TRAILING.sub("", text)


def is_number(value: Any) -> bool:
    """typeof value === "number", for Python's numbers (bool is not one)."""
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _in_double_range(value: int) -> bool:
    """An int a JavaScript number can hold: one that does not overflow a double."""
    try:
        float(value)
    except OverflowError:
        return False
    return True


def is_finite(value: Any) -> bool:
    """Number.isFinite. An int past a double's range is no number JavaScript has."""
    if isinstance(value, bool):
        return False
    if isinstance(value, int):
        return _in_double_range(value)
    return isinstance(value, float) and math.isfinite(value)


def is_integer(value: Any) -> bool:
    """Number.isInteger."""
    if isinstance(value, bool):
        return False
    if isinstance(value, int):
        return _in_double_range(value)
    return isinstance(value, float) and math.isfinite(value) and value == math.floor(value)


def js_round(value: float) -> Any:
    """Math.round: halves go up, toward positive infinity. Returns an int for a finite value."""
    if isinstance(value, int) and not isinstance(value, bool):
        return value
    if not math.isfinite(value):
        return value
    floor = math.floor(value)
    return floor + 1 if value - floor >= 0.5 else floor


def decimal(value: float) -> tuple[str, int]:
    """The shortest digits that round-trip, and where the decimal point goes:
    value = 0.DIGITS * 10**point. Python's repr already finds the digits."""
    text = repr(float(value))
    if "e" in text:
        mantissa, exponent = text.split("e")
        digits = mantissa.replace(".", "")
        point = int(exponent) + 1
    else:
        whole, _, fraction = text.partition(".")
        if whole == "0":
            stripped = fraction.lstrip("0")
            point = -(len(fraction) - len(stripped))
            digits = stripped
        else:
            digits = whole + fraction
            point = len(whole)
    digits = digits.rstrip("0")
    return (digits or "0"), point


def number(value: Any) -> str:
    """String(number): the text a template literal or JSON.stringify gives a number."""
    if isinstance(value, int) and not isinstance(value, bool) and abs(value) <= MAX_SAFE_INTEGER:
        return str(value)
    value = float(value)
    if math.isnan(value):
        return "NaN"
    if math.isinf(value):
        return "Infinity" if value > 0 else "-Infinity"
    if value == 0:
        return "0"
    digits, point = decimal(abs(value))
    k = len(digits)
    if k <= point <= 21:
        text = digits + "0" * (point - k)
    elif 0 < point <= 21:
        text = f"{digits[:point]}.{digits[point:]}"
    elif -6 < point <= 0:
        text = f"0.{'0' * -point}{digits}"
    else:
        exponent = point - 1
        mantissa = digits if k == 1 else f"{digits[0]}.{digits[1:]}"
        text = f"{mantissa}e{'-' if exponent < 0 else '+'}{abs(exponent)}"
    return f"-{text}" if value < 0 else text


def length16(text: str) -> int:
    """Length in UTF-16 code units, which is what String#length is in JavaScript."""
    if text.isascii():
        return len(text)
    return len(text.encode("utf-16-le", "surrogatepass")) // 2


def head16(text: str, units: int) -> str:
    """text.slice(0, units), counted in UTF-16 code units. A surrogate pair cut
    in half leaves U+FFFD, the character a lone surrogate becomes once written
    out as UTF-8 (to a store, a hash, or a network)."""
    if text.isascii():
        return text[: max(units, 0)]
    data = text.encode("utf-16-le", "surrogatepass")
    return data[: max(units, 0) * 2].decode("utf-16-le", "replace")


def tail16(text: str, units: int) -> str:
    """text.slice(-units), counted in UTF-16 code units, the same way."""
    if units <= 0:
        return ""
    if text.isascii():
        return text[-units:]
    data = text.encode("utf-16-le", "surrogatepass")
    return data[-units * 2 :].decode("utf-16-le", "replace")


def well_formed(text: str) -> str:
    """Text with any lone surrogate (which Python's str can hold, and UTF-8
    cannot) made U+FFFD, as JavaScript writes one out."""
    if text.isascii():
        return text
    try:
        text.encode("utf-8")
        return text
    except UnicodeEncodeError:
        return text.encode("utf-16-le", "surrogatepass").decode("utf-16-le", "replace")


def quote(text: str) -> str:
    """A string as JSON.stringify writes it."""

    def escape(match: re.Match[str]) -> str:
        c = match.group(0)
        return _ESCAPES.get(c) or f"\\u{ord(c):04x}"

    return '"' + _NEEDS_ESCAPE.sub(escape, text) + '"'


def object_keys(mapping: Mapping[Any, Any]) -> list[Any]:
    """Property order: array-index keys ascending, then the rest as inserted."""
    keys = list(mapping.keys())
    indexes = [k for k in keys if _INDEX_KEY.match(str(k)) and int(str(k)) < 4_294_967_295]
    if not indexes:
        return keys
    rest = [k for k in keys if k not in set(indexes)]
    return sorted(indexes, key=lambda k: int(str(k))) + rest


def to_json_value(value: Any) -> Any:
    """Anything with to_dict() as its JSON shape; everything else as it is."""
    to_dict = getattr(value, "to_dict", None)
    if callable(to_dict) and not isinstance(value, (dict, list, str)):
        return to_dict()
    return value


def dumps(value: Any) -> str:
    """JSON.stringify for plain data: dicts, lists, strings, numbers, True,
    False, and None, and anything with a to_dict() (this package's types).
    Raises TypeError for anything else."""
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, str):
        return quote(value)
    if isinstance(value, int):
        return number(value)
    if isinstance(value, float):
        return number(value) if math.isfinite(value) else "null"
    if isinstance(value, Mapping):
        parts = []
        for key in object_keys(value):
            item = value[key]
            if item is _UNDEFINED:
                continue
            parts.append(f"{quote(str(key))}:{dumps(item)}")
        return "{" + ",".join(parts) + "}"
    if isinstance(value, (list, tuple)):
        return "[" + ",".join("null" if v is _UNDEFINED else dumps(v) for v in value) + "]"
    converted = to_json_value(value)
    if converted is not value:
        return dumps(converted)
    raise TypeError(f"{type(value).__name__} is not JSON serializable")


class _Undefined:
    """A value JSON.stringify leaves out, as it leaves out undefined."""

    def __repr__(self) -> str:
        return "undefined"


_UNDEFINED = _Undefined()


def loads(text: str | bytes) -> Any:
    """JSON.parse. Python's parser keeps key order, as JavaScript does."""
    return json.loads(text)


def iso(at: int | float) -> str:
    """Date#toISOString for epoch milliseconds."""
    ms = int(math.floor(at))
    seconds, millis = divmod(ms, 1000)
    days, rest = divmod(seconds, 86_400)
    year, month, day = civil_from_days(days)
    hour, rest = divmod(rest, 3600)
    minute, second = divmod(rest, 60)
    return f"{year:04d}-{month:02d}-{day:02d}T{hour:02d}:{minute:02d}:{second:02d}.{millis:03d}Z"


def days_from_civil(year: int, month: int, day: int) -> int:
    """Days since 1970-01-01 of a proleptic Gregorian date (month 1 to 12)."""
    year -= month <= 2
    era = (year if year >= 0 else year - 399) // 400
    yoe = year - era * 400
    doy = (153 * (month + (-3 if month > 2 else 9)) + 2) // 5 + day - 1
    doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146_097 + doe - 719_468


def civil_from_days(days: int) -> tuple[int, int, int]:
    """The (year, month, day) of a count of days since 1970-01-01."""
    days += 719_468
    era = (days if days >= 0 else days - 146_096) // 146_097
    doe = days - era * 146_097
    yoe = (doe - doe // 1460 + doe // 36_524 - doe // 146_096) // 365
    y = yoe + era * 400
    doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    mp = (5 * doy + 2) // 153
    d = doy - (153 * mp + 2) // 5 + 1
    m = mp + (3 if mp < 10 else -9)
    return y + (m <= 2), m, d


def date_utc(year: int, month: int, day: int = 1, hour: int = 0, minute: int = 0, second: int = 0, ms: int = 0) -> int:
    """Date.UTC, month 0 based, every field free to overflow into the next."""
    year += month // 12
    month %= 12
    days = days_from_civil(year, month + 1, 1) + day - 1
    return (((days * 24 + hour) * 60 + minute) * 60 + second) * 1000 + ms
