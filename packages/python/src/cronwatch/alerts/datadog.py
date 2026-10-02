"""Datadog Events API v1 (alerts/datadog.ts).
API reference: https://docs.datadoghq.com/api/latest/events/ (Post an event)
POST https://api.<site>/api/v1/events with DD-API-KEY. Answers 202."""

from __future__ import annotations

import math
import re
from collections.abc import Callable, Sequence
from typing import Any

from .. import _js
from .._deprecated import names as _deprecated_names
from ..types import Alert
from ._http import HTTP
from ._shared import cut, http_or_default, link_for, plain_text, post, present, required, sha256_hex

__all__ = ["Datadog"]

_ALERT_TYPE = {
    "missed": "error",
    "failed": "error",
    "stuck": "error",
    "slow": "warning",
    "over_budget": "warning",
    "under_floor": "warning",
    "recovered": "success",
}

_SCHEME = re.compile(r"^https?://")
_SUBDOMAIN = re.compile(r"^(api|app)\.")
_TRAILING_SLASHES = re.compile(r"/+\Z")
_SITE = re.compile(r"^[a-z0-9.-]+\Z", re.IGNORECASE | re.ASCII)


class Datadog:
    """Posts alerts to the Datadog event stream, aggregated per job and alert
    type. ``site`` is your Datadog site: "datadoghq.com" (the default),
    "datadoghq.eu", "us3.datadoghq.com", "us5.datadoghq.com",
    "ap1.datadoghq.com", "ddog-gov.com". Every event is tagged cronwatch,
    job:<name> and alert:<type>, then ``tags``."""

    name = "datadog"

    def __init__(
        self,
        *,
        api_key: str,
        site: str | None = None,
        tags: Sequence[str] | None = None,
        host: str | None = None,
        link: Callable[[Alert], Any] | None = None,
        http: HTTP | None = None,
    ) -> None:
        # A pasted credential often carries a stray space or newline, which a header would refuse or send.
        self._api_key = required(api_key, "Datadog() needs an api_key")
        chosen = "datadoghq.com" if site is None else str(site)
        chosen = _TRAILING_SLASHES.sub("", _SUBDOMAIN.sub("", _SCHEME.sub("", chosen, count=1), count=1))
        if not _SITE.search(chosen):
            raise ValueError("Datadog() needs a site like datadoghq.com")
        self._url = f"https://api.{chosen}/api/v1/events"
        self._tags = list(tags or [])
        self._host = host
        self._link = link
        self._http = http_or_default(http)

    def send(self, alert: Alert, context: Any = None) -> None:
        link = link_for(self._link, alert)
        event: dict[str, Any] = {
            "title": cut(alert.title, 500),
            "text": cut(plain_text(alert, link), 4000),
            "alert_type": _ALERT_TYPE[str(alert.type)],
            "aggregation_key": _aggregation_key(alert),
            "date_happened": math.floor(alert.at / 1000),
            "priority": "normal",
            "tags": ["cronwatch", f"job:{alert.job}", f"alert:{alert.type}", *self._tags],
        }
        if present(self._host):
            event["host"] = self._host
        headers = {"content-type": "application/json", "accept": "application/json", "dd-api-key": self._api_key}
        post(self._http, "Datadog", self._url, headers, _js.dumps(event), [self._api_key])


def _aggregation_key(alert: Alert) -> str:
    """"cronwatch:<job>:<type>", or a hash of it when that passes Datadog's 100 characters."""
    key = f"cronwatch:{alert.job}:{alert.type}"
    return key if _js.length16(key) <= 100 else f"cronwatch:{sha256_hex(key)[:40]}"


#: Internal names, still answering under their old public names (each
#: warning, until 1.0 removes them).
__getattr__ = _deprecated_names(__name__, globals(), {"ALERT_TYPE": "_ALERT_TYPE", "aggregation_key": "_aggregation_key"})
