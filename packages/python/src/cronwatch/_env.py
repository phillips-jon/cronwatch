"""The environment, read in one place (the SDK reads NODE_ENV). Python has no
single convention, so the first of CRONWATCH_ENV, APP_ENV and ENVIRONMENT
that is set is used; the Django integration (a later release) reads DEBUG."""

from __future__ import annotations

import os

_VARIABLES = ("CRONWATCH_ENV", "APP_ENV", "ENVIRONMENT")


def environment() -> str | None:
    for name in _VARIABLES:
        value = os.environ.get(name)
        if value:
            return value.strip().lower()
    return None


def is_production() -> bool:
    return environment() in ("production", "prod")


def is_development() -> bool:
    return environment() in ("development", "dev", "test")
