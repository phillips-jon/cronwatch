"""The Django integration: settings, the dashboard's URLs and a management
command for cron. Needs Django 5.2 or newer (`pip install "cronwatch-sdk[django]"`).

    # settings.py
    INSTALLED_APPS = [..., "cronwatch.django"]
    CRONWATCH = {
        "STORE": "myapp.monitoring.store",   # a store, or a dotted path to one (or to a class or function making one)
        "ALERTS": [Slack(webhook_url=...)],  # channels, or dotted paths to them
        "TOKEN": os.environ["CRONWATCH_TOKEN"],
    }

    # urls.py
    urlpatterns = [..., path("cronwatch/", include("cronwatch.django.urls"))]

    # crontab: look for missed and stuck runs every five minutes
    */5 * * * * cd /app && python manage.py cronwatch_check

The client's options are CRONWATCH's STORE, ALERTS, TRIAGE, SOURCES,
CRON_SECRET, RETENTION, DEFAULTS, REDACT, DELIVER, and ON_ERROR (cronwatch.Cronwatch's
options, upper case); with any of them set, cronwatch.django.client() makes the
process's client from them on first use (cronwatch.configure), so
cronwatch.client() hands out the same one. CLIENT instead names a client the
app made itself (the client or a dotted path to it). With none of them, the
dashboard and the command use cronwatch.client(), whatever the app configured.
The dashboard's options are TOKEN, BASE_PATH, ORIGIN, and TRUST_PROXY (see
cronwatch.web); the base path defaults to where the URLs are included, and the
request's origin is Django's (request.scheme and request.get_host(), so
SECURE_PROXY_SSL_HEADER and USE_X_FORWARDED_HOST apply).

DEBUG is the environment when CRONWATCH_ENV, APP_ENV, and ENVIRONMENT are all
unset, the way the SDK reads NODE_ENV: on, it is development (the dashboard
makes a token and prints its sign-in link when TOKEN and $CRONWATCH_TOKEN are
unset); off, it is production (no token is made: the dashboard answers 503).
"""

from __future__ import annotations

import threading
from typing import Any

try:
    import django  # noqa: F401
except ImportError as error:  # pragma: no cover
    raise ImportError('cronwatch.django needs Django: pip install "cronwatch-sdk[django]"') from error

import cronwatch
from cronwatch import _env
from cronwatch.web import Web

from .._deprecated import names as _deprecated_names

__all__ = ["DjangoWeb", "client", "reset", "routes"]

_CLIENT_OPTIONS = {
    "STORE": "store",
    "ALERTS": "alerts",
    "TRIAGE": "triage",
    "SOURCES": "sources",
    "CRON_SECRET": "cron_secret",
    "RETENTION": "retention",
    "DEFAULTS": "defaults",
    "REDACT": "redact",
    "DELIVER": "deliver",
    "ON_ERROR": "on_error",
}
_WEB_OPTIONS = {"TOKEN": "token", "BASE_PATH": "base_path", "ORIGIN": "origin", "TRUST_PROXY": "trust_proxy"}
_KEYS = ("CLIENT", *_CLIENT_OPTIONS, *_WEB_OPTIONS)

_lock = threading.Lock()
_client: Any = None
_routes: Any = None


def _debug_environment() -> str | None:
    from django.conf import settings

    if not settings.configured:
        return None
    return "development" if settings.DEBUG else "production"


_env.set_fallback(_debug_environment)


def _settings() -> dict[str, Any]:
    from django.conf import settings
    from django.core.exceptions import ImproperlyConfigured

    value = getattr(settings, "CRONWATCH", None)
    if value is None:
        return {}
    if not isinstance(value, dict):
        raise ImproperlyConfigured("CRONWATCH must be a dict")
    unknown = [key for key in value if key not in _KEYS]
    if unknown:
        raise ImproperlyConfigured(f"CRONWATCH has {', '.join(map(repr, unknown))}; it takes {', '.join(_KEYS)}")
    return dict(value)


def _load(value: Any, *, makes: str | None = None) -> Any:
    """A dotted path imported, and a class or a function called once to make
    the thing (a store, a channel, a source) when what it names is not one yet."""
    from django.utils.module_loading import import_string

    if isinstance(value, str):
        value = import_string(value)
    if makes is not None and (isinstance(value, type) or (callable(value) and not hasattr(value, makes))):
        value = value()
    return value


def _client_options(config: dict[str, Any]) -> dict[str, Any]:
    options: dict[str, Any] = {}
    for key, name in _CLIENT_OPTIONS.items():
        if key not in config:
            continue
        value = config[key]
        if key == "STORE" and value is not None:
            value = _load(value, makes="insert_run")
        elif key == "ALERTS" and value is not None:
            value = [_load(item, makes="send") for item in value]
        elif key == "SOURCES" and value is not None:
            value = [_load(item, makes="sync") for item in value]
        elif key in ("TRIAGE", "ON_ERROR", "REDACT") and isinstance(value, str):
            value = _load(value)
        options[name] = value
    return options


def client() -> cronwatch.Cronwatch:
    """The client the dashboard and cronwatch_check use: CLIENT when set,
    otherwise one made from CRONWATCH's client options on first use (and made
    the process's client), otherwise cronwatch.client(). Called on every
    dashboard request and task, so a client already made is returned before
    anything else is read: the STORE, ALERTS, and SOURCES factories run once,
    when it is made, never again on a later call."""
    global _client
    made: cronwatch.Cronwatch | None = _client
    if made is not None:
        return made
    config = _settings()
    if config.get("CLIENT") is not None:
        found: cronwatch.Cronwatch = _load(config["CLIENT"])
        return found
    if not any(key in config for key in _CLIENT_OPTIONS):
        return cronwatch.client()
    with _lock:
        if _client is None:
            _client = cronwatch.configure(**_client_options(config))
        made = _client
    return made


class DjangoWeb(Web):
    """The dashboard, on the client cronwatch.django.client() gives."""

    @property
    def client(self) -> Any:
        return client()


def routes() -> Web:
    """The dashboard (a cronwatch.web.Web) made from CRONWATCH's TOKEN,
    BASE_PATH, ORIGIN, and TRUST_PROXY, once; its client is client()."""
    global _routes
    with _lock:
        if _routes is None:
            config = _settings()
            options = {name: config[key] for key, name in _WEB_OPTIONS.items() if key in config}
            _routes = DjangoWeb(**options)
        made: Web = _routes
    return made


def reset() -> None:
    """Forgets the client and dashboard made from the settings, so the next
    use reads them again (Django's setting_changed signal calls this when a
    test overrides CRONWATCH or DEBUG). A client made here is stopped."""
    global _client, _routes
    with _lock:
        previous, _client, _routes = _client, None, None
    if previous is not None:
        previous.stop()


#: Internal names, still answering under their old public names (each
#: warning, until 1.0 removes them).
__getattr__ = _deprecated_names(__name__, globals(), {"CLIENT_OPTIONS": "_CLIENT_OPTIONS", "WEB_OPTIONS": "_WEB_OPTIONS", "KEYS": "_KEYS"})
