"""Test helpers, as the SDK's test/helpers.ts has them."""

from __future__ import annotations

from collections.abc import Callable, Iterable
from typing import Any

import cronwatch
from cronwatch import Alert, Cronwatch
from cronwatch._js import date_utc

T0 = date_utc(2026, 0, 5, 9, 30, 0)  # Monday 2026-01-05 09:30:00Z
SEC = 1000
MIN = 60_000
HOUR = 3_600_000
DAY = 86_400_000


class Clock:
    def __init__(self, start: int = T0) -> None:
        self.at = start

    def now(self) -> int:
        return self.at

    def set(self, at: int) -> None:
        self.at = at

    def advance(self, ms: int) -> int:
        self.at += ms
        return self.at


class Capture:
    """An alert channel that keeps what it is sent."""

    name = "capture"

    def __init__(self) -> None:
        self.alerts: list[Alert] = []

    def send(self, alert: Alert, context: Any = None) -> None:
        self.alerts.append(alert)

    def types(self) -> list[str]:
        return [str(a.type) for a in self.alerts]


class Flaky:
    """Wraps a store so the named methods raise while they are in `broken`."""

    def __init__(self, store: Any, broken: set[str]) -> None:
        self._store = store
        self.broken = broken

    def __getattr__(self, name: str) -> Any:
        value = getattr(self._store, name)
        if not callable(value):
            return value

        def call(*args: Any, **kwargs: Any) -> Any:
            if name in self.broken:
                raise RuntimeError(f"store down: {name}")
            return value(*args, **kwargs)

        return call


class Wrapped:
    """A store with some methods replaced, the rest passed through."""

    def __init__(self, store: Any, **overrides: Callable[..., Any]) -> None:
        self._store = store
        self._overrides = overrides

    def __getattr__(self, name: str) -> Any:
        if name in self._overrides:
            return self._overrides[name]
        return getattr(self._store, name)


class Without:
    """A store without some optional methods."""

    def __init__(self, store: Any, missing: Iterable[str]) -> None:
        self._store = store
        self._missing = set(missing)

    def __getattr__(self, name: str) -> Any:
        if name in self._missing:
            raise AttributeError(name)
        return getattr(self._store, name)


class Errors:
    """An on_error that keeps what it is given."""

    def __init__(self) -> None:
        self.items: list[tuple[BaseException, str]] = []

    def __call__(self, error: BaseException, where: str) -> None:
        self.items.append((error, where))

    @property
    def wheres(self) -> list[str]:
        return [w for _, w in self.items]

    @property
    def messages(self) -> list[str]:
        return [str(e) for e, _ in self.items]


def make(clock: Clock | None = None, **options: Any) -> tuple[Cronwatch, Clock, Capture]:
    c = clock or Clock()
    alerts = Capture()
    settings: dict[str, Any] = {"now": c.now, "alerts": [alerts], "cron_secret": None}
    settings.update(options)
    return cronwatch.Cronwatch(**settings), c, alerts


def boom(message: str = "x") -> Callable[[Any], Any]:
    def fail(_ctx: Any = None) -> Any:
        raise RuntimeError(message)

    return fail
