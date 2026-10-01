"""Sentry, through the envelope endpoint (alerts/sentry.ts).
Envelopes: https://develop.sentry.dev/sdk/data-model/envelopes/
Event payload: https://develop.sentry.dev/sdk/data-model/event-payloads/
DSN and X-Sentry-Auth: https://develop.sentry.dev/sdk/foundations/transport/authentication/"""

from __future__ import annotations

import re
import urllib.parse
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

from .. import _js
from .._deprecated import names as _deprecated_names
from ..types import Alert, _details_to_json
from ._http import HTTP
from ._shared import alert_id, cut, host_of, http_or_default, link_for, post, present, required, run_summary, severity

__all__ = ["Sentry"]

_DIGITS = re.compile(r"^\d+\Z")


@dataclass
class _Dsn:
    endpoint: str
    public_key: str


def _parse_dsn(dsn: str) -> _Dsn:
    """"https://<key>@<host>/<project>" as the envelope endpoint and the public key."""
    try:
        parts = urllib.parse.urlsplit(dsn)
        host = host_of(parts)
    except ValueError:
        raise ValueError("Sentry() needs a valid dsn") from None
    if not parts.scheme or not host:
        raise ValueError("Sentry() needs a valid dsn")
    segments = [s for s in parts.path.split("/") if s]
    project = segments.pop() if segments else None
    if not parts.username or project is None or not _DIGITS.search(project):
        raise ValueError("Sentry() needs a dsn like https://<key>@<host>/<project>")
    prefix = "/" + "/".join(segments) if segments else ""
    return _Dsn(endpoint=f"{parts.scheme.lower()}://{host}{prefix}/api/{project}/envelope/", public_key=urllib.parse.unquote(parts.username))


class Sentry:
    """Sends alerts to Sentry as events, one issue per job and alert type.
    Recoveries go too, as info events, unless ``recovered=False``::

        Sentry(dsn=os.environ["SENTRY_DSN"], environment="production")
    """

    name = "sentry"

    def __init__(
        self,
        *,
        dsn: str,
        environment: str | None = None,
        release: str | None = None,
        recovered: bool = True,
        link: Callable[[Alert], Any] | None = None,
        http: HTTP | None = None,
    ) -> None:
        # A pasted credential often carries a stray space or newline, which a header would refuse or send.
        parsed = _parse_dsn(required(dsn, "Sentry() needs a dsn"))
        self._endpoint = parsed.endpoint
        self._public_key = parsed.public_key
        self._environment = environment
        self._release = release
        self._recovered = recovered
        self._link = link
        self._http = http_or_default(http)

    def send(self, alert: Alert, context: Any = None) -> None:
        if str(alert.type) == "recovered" and self._recovered is False:
            return
        event_id = alert_id(alert)
        link = link_for(self._link, alert)
        event: dict[str, Any] = {
            "event_id": event_id,
            "timestamp": alert.at / 1000,
            "platform": "other",
            "level": severity(alert.type),
            "logger": "cronwatch",
            "transaction": alert.job,
            "environment": "production" if self._environment is None else self._environment,
        }
        if present(self._release):
            event["release"] = self._release
        # The first line is the issue title.
        event["logentry"] = {"formatted": cut(f"{alert.title}\n\n{alert.message}", 8192)}
        event["fingerprint"] = ["cronwatch", alert.job, str(alert.type)]
        event["tags"] = {"job": cut(alert.job, 199), "type": str(alert.type)}
        extra: dict[str, Any] = {}
        if present(alert.triage):
            extra["triage"] = alert.triage
        if link:
            extra["link"] = link
        extra["details"] = _details_to_json(alert.details)
        extra["run"] = run_summary(alert)
        event["extra"] = extra
        payload = _js.dumps(event)
        envelope = (
            "\n".join(
                [
                    _js.dumps({"event_id": event_id}),
                    _js.dumps({"type": "event", "content_type": "application/json", "length": len(_js.well_formed(payload).encode("utf-8"))}),
                    payload,
                ]
            )
            + "\n"
        )
        headers = {
            "content-type": "application/x-sentry-envelope",
            "x-sentry-auth": f"Sentry sentry_version=7, sentry_key={self._public_key}, sentry_client=cronwatch",
        }
        post(self._http, "Sentry", self._endpoint, headers, envelope, [self._public_key])


#: Names 1.0 made internal, still answering under their old names (each
#: warning, until 2.0).
__getattr__ = _deprecated_names(__name__, globals(), {"Dsn": "_Dsn", "parse_dsn": "_parse_dsn"})
