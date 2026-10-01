"""The environment, read in one place, as every CronWatch library reads it:
the first of CRONWATCH_ENV, APP_ENV and ENVIRONMENT that holds more than
spaces, trimmed and lowercased, with "prod" read as "production" and "dev",
"local", "test" and "testing" as "development". Failing those, a framework
integration may name one (cronwatch.django reads DEBUG: development when it
is on, production when off). None when nothing names one, which is neither.
It decides whether the in-memory store warns that it forgets on restart, and
whether the web routes make a development token when none is configured."""

from __future__ import annotations

import os
from collections.abc import Callable

from . import _js

__all__ = ["environment", "is_development", "is_production", "set_fallback"]

_VARIABLES = ("CRONWATCH_ENV", "APP_ENV", "ENVIRONMENT")
_ALIASES = {"prod": "production", "dev": "development", "local": "development", "test": "development", "testing": "development"}
_fallback: Callable[[], str | None] | None = None


def set_fallback(read: Callable[[], str | None] | None) -> None:
    """What names the environment when no variable does (a framework's own setting), or None for nothing."""
    global _fallback
    _fallback = read


def _name(value: str | None) -> str | None:
    """A value trimmed as JavaScript trims and lowercased, its alias resolved; None for one of only spaces."""
    name = _js.trim(value).lower() if isinstance(value, str) else ""
    return _ALIASES.get(name, name) or None


def environment() -> str | None:
    for variable in _VARIABLES:
        name = _name(os.environ.get(variable))
        if name is not None:
            return name
    read = _fallback
    if read is not None:
        try:
            return _name(read())
        except Exception:
            return None
    return None


def is_production() -> bool:
    return environment() == "production"


def is_development() -> bool:
    return environment() == "development"
