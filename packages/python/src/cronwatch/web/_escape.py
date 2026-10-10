"""What the pages need to write values the way the SDK's templates do:
escapeHtml, String(value), JavaScript truthiness, encodeURIComponent,
toFixed, and Object.entries."""

from __future__ import annotations

import math
import re
from collections.abc import Mapping
from fractions import Fraction
from typing import Any
from urllib.parse import quote

from .. import _js

__all__ = ["encode_uri_component", "entries", "h", "name_html", "text", "to_fixed", "truthy"]


def text(value: Any) -> str:
    """String(value), the way a template literal writes it (None as "", as `?? ""` has it)."""
    if value is None:
        return ""
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, str):
        return str.__str__(value)
    if isinstance(value, (int, float)):
        return _js.number(value)
    if isinstance(value, (list, tuple)):
        return ",".join("" if v is None else text(v) for v in value)
    if isinstance(value, Mapping):
        return "[object Object]"
    return str(value)


def h(value: Any) -> str:
    """escapeHtml: String(value ?? "") with & < > " ' escaped. Every string a page shows goes through this."""
    return text(value).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;").replace("'", "&#39;")


_SEPARATORS = re.compile(r"([_:./-]+)(?=[^_:./-])")


def name_html(value: Any) -> str:
    """escapeName: a job name shown as text, with a break allowed after each run
    of _ : . / - so it wraps at its separators. Never in an attribute."""
    return _SEPARATORS.sub(r"\1<wbr>", h(value))


def truthy(value: Any) -> bool:
    """JavaScript truthiness, for the templates' `x ? a : b`: an empty list or dict is true there."""
    if value is None or value is False or value == "":
        return False
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return not (value == 0 or (isinstance(value, float) and math.isnan(value)))
    return True


def encode_uri_component(value: Any) -> str:
    """encodeURIComponent. A lone surrogate, which it refuses, becomes U+FFFD first."""
    return quote(_js.well_formed(text(value)), safe="-_.!~*'()")


def to_fixed(value: float, digits: int) -> str:
    """Number.prototype.toFixed: the nearest `digits`-place decimal to the exact
    value of the double, halves away from zero."""
    if not _js.is_finite(value) or abs(value) >= 1e21:
        return _js.number(value)
    scaled = math.floor(abs(Fraction(value)) * 10**digits + Fraction(1, 2))
    out = str(scaled)
    if digits > 0:
        out = out.rjust(digits + 1, "0")
        out = f"{out[:-digits]}.{out[-digits:]}"
    return f"-{out}" if value < 0 else out


def entries(mapping: Any) -> list[tuple[str, Any]]:
    """Object.entries: integer-like keys first, ascending, then the rest in insertion order."""
    if not isinstance(mapping, Mapping):
        return []
    return [(str(k), mapping[k]) for k in _js.object_keys(mapping)]
