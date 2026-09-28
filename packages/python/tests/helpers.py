"""Test helpers, as the SDK's test/helpers.ts has them."""

from __future__ import annotations

import os
import uuid
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


#: A Postgres URL for the Postgres store's tests; they are skipped without one.
PG = os.environ.get("CRONWATCH_TEST_PG") or None
NO_PG = "set CRONWATCH_TEST_PG to a Postgres URL to run"
#: A Postgres with pg_cron (in cron.database_name) for the pg_cron source's tests against the real extension.
PGCRON = os.environ.get("CRONWATCH_TEST_PGCRON") or None
NO_PGCRON = "set CRONWATCH_TEST_PGCRON to the URL of a Postgres with pg_cron (in cron.database_name) to run"


class WebResponse:
    """A response from the routes, read the way the SDK tests read a fetch Response."""

    def __init__(self, status: int, headers: dict[str, str], body: bytes) -> None:
        self.status = status
        self.headers = headers
        self.body = body

    @property
    def text(self) -> str:
        return self.body.decode("utf-8")

    def json(self) -> Any:
        import json

        return json.loads(self.body)


def send(
    app: Any,
    method: str,
    url: str,
    headers: dict[str, str] | None = None,
    body: str | bytes | None = None,
    script_name: str = "",
    raw: bool = True,
) -> WebResponse:
    """Sends one request to a WSGI app, as a server would: the path decoded in
    PATH_INFO and, with `raw`, the request target as sent in RAW_URI (as
    gunicorn passes it). `url` may be a path on http://app.test."""
    import io
    from urllib.parse import unquote_to_bytes, urlsplit

    if url.startswith("/"):
        url = f"http://app.test{url}"
    scheme, netloc, _, _, _ = urlsplit(url)
    target = url[len(f"{scheme}://{netloc}") :] or "/"
    path, _, query = target.partition("?")
    data = body.encode() if isinstance(body, str) else (body or b"")
    decoded = unquote_to_bytes(path).decode("latin-1")
    environ: dict[str, Any] = {
        "REQUEST_METHOD": method,
        "SCRIPT_NAME": script_name,
        "PATH_INFO": decoded[len(script_name) :] if script_name and decoded.startswith(script_name) else decoded,
        "QUERY_STRING": query,
        "SERVER_NAME": netloc.split(":")[0],
        "SERVER_PORT": netloc.split(":")[1] if ":" in netloc else ("443" if scheme == "https" else "80"),
        "SERVER_PROTOCOL": "HTTP/1.1",
        "HTTP_HOST": netloc,
        "wsgi.url_scheme": scheme,
        "wsgi.input": io.BytesIO(data),
        "wsgi.errors": io.StringIO(),
    }
    if raw:
        environ["RAW_URI"] = target
    if data:
        environ["CONTENT_LENGTH"] = str(len(data))
    for name, value in (headers or {}).items():
        key = name.upper().replace("-", "_")
        environ[key if key in ("CONTENT_TYPE", "CONTENT_LENGTH") else f"HTTP_{key}"] = value
    started: dict[str, Any] = {}

    def start_response(status: str, response_headers: list[tuple[str, str]]) -> None:
        started["status"] = int(status.split(" ", 1)[0])
        started["headers"] = dict(response_headers)

    out = b"".join(app(environ, start_response))
    return WebResponse(started["status"], started["headers"], out)


def pg_prefix(label: str = "t") -> str:
    """Tables of their own for one test, so tests never see each other's rows."""
    return f"py{label}{os.getpid()}_{uuid.uuid4().hex[:8]}_"


def drop_pg_tables(prefix: str) -> None:
    import psycopg

    with psycopg.connect(PG or "", autocommit=True) as connection:
        connection.execute(f"DROP TABLE IF EXISTS {prefix}jobs, {prefix}runs, {prefix}state")


def make(clock: Clock | None = None, **options: Any) -> tuple[Cronwatch, Clock, Capture]:
    c = clock or Clock()
    alerts = Capture()
    settings: dict[str, Any] = {"now": c.now, "alerts": [alerts], "cron_secret": None}
    settings.update(options)
    return cronwatch.Cronwatch(**settings), c, alerts


def run_python(script: str, work: Any, timeout: float = 120, **env: str) -> Any:
    """Runs a script in a Python process of its own, in `work` (which is on
    its path, beside the tests), and returns the finished process; it must succeed."""
    import subprocess
    import sys

    here = os.path.dirname(os.path.abspath(__file__))
    path = os.pathsep.join(p for p in (str(work), here, os.environ.get("PYTHONPATH", "")) if p)
    environ = {**os.environ, "PYTHONPATH": path, "WORK": str(work), **env}
    done = subprocess.run([sys.executable, "-c", script], cwd=str(work), env=environ, capture_output=True, text=True, timeout=timeout)
    assert done.returncode == 0, f"exit {done.returncode}\n{done.stdout}\n{done.stderr}"
    return done


def boom(message: str = "x") -> Callable[[Any], Any]:
    def fail(_ctx: Any = None) -> Any:
        raise RuntimeError(message)

    return fail
