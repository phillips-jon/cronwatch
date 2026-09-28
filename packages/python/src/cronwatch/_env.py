"""The environment, read in one place (the SDK reads NODE_ENV). Python has no
single convention, so the first of CRONWATCH_ENV, APP_ENV and ENVIRONMENT
that is set is used; failing those, a framework integration may name one
(cronwatch.django reads DEBUG: development when it is on, production when off).
It decides whether the in-memory store warns that it forgets on restart, and
whether the web routes make a development token when none is configured."""

from __future__ import annotations

import os
from collections.abc import Callable

_VARIABLES = ("CRONWATCH_ENV", "APP_ENV", "ENVIRONMENT")
_fallback: Callable[[], str | None] | None = None


def set_fallback(read: Callable[[], str | None] | None) -> None:
    """What names the environment when no variable does (a framework's own setting), or None for nothing."""
    global _fallback
    _fallback = read


def environment() -> str | None:
    for name in _VARIABLES:
        value = os.environ.get(name)
        if value:
            return value.strip().lower()
    read = _fallback
    if read is not None:
        try:
            value = read()
        except Exception:
            return None
        return value.strip().lower() if value else None
    return None


def is_production() -> bool:
    return environment() in ("production", "prod")


def is_development() -> bool:
    return environment() in ("development", "dev", "test")
