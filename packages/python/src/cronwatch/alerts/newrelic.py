"""New Relic Event API (alerts/newrelic.ts). API reference:
https://docs.newrelic.com/docs/data-apis/ingest-apis/event-api/introduction-event-api/
POST https://insights-collector.newrelic.com/v1/accounts/<id>/events
(insights-collector.eu01.nr-data.net for EU accounts) with Api-Key."""

from __future__ import annotations

import re
from collections.abc import Callable
from typing import Any

from .. import _js
from ..types import Alert
from ._http import HTTP
from ._shared import cut, http_or_default, link_for, post, present, required, severity

__all__ = ["NewRelic"]

_DIGITS = re.compile(r"^\d+\Z")


class NewRelic:
    """Records alerts as New Relic custom events. Each alert is one event of
    type CronWatchAlert (or ``event_type``), queryable with NRQL:
    SELECT * FROM CronWatchAlert WHERE job = 'nightly'. ``api_key`` is a
    license key; ``region="eu"`` for an account in the EU data center."""

    name = "newrelic"

    def __init__(
        self,
        *,
        account_id: str | int,
        api_key: str,
        region: str | None = None,
        event_type: str | None = None,
        link: Callable[[Alert], Any] | None = None,
        http: HTTP | None = None,
    ) -> None:
        # A pasted credential often carries a stray space or newline, which a header would refuse or send.
        self._api_key = required(api_key, "NewRelic() needs an api_key")
        account = "" if account_id is None else _js.number(account_id) if _js.is_number(account_id) else str(account_id)
        if not _DIGITS.search(account):
            raise ValueError("NewRelic() needs a numeric account_id")
        host = "https://insights-collector.eu01.nr-data.net" if region == "eu" else "https://insights-collector.newrelic.com"
        self._url = f"{host}/v1/accounts/{account}/events"
        self._event_type = "CronWatchAlert" if event_type is None else str(event_type)
        self._link = link
        self._http = http_or_default(http)

    def send(self, alert: Alert, context: Any = None) -> None:
        link = link_for(self._link, alert)
        run = alert.run
        # Flat attributes only, strings under 4096 characters.
        event: dict[str, Any] = {
            "eventType": self._event_type,
            "timestamp": alert.at,
            "job": cut(alert.job, 4095),
            "alertType": str(alert.type),
            "severity": severity(alert.type),
            "title": cut(alert.title, 4095),
            "message": cut(alert.message, 4095),
        }
        if present(alert.triage):
            event["triage"] = cut(str(alert.triage), 4095)
        if link:
            event["link"] = cut(link, 4095)
        if run is not None:
            event["runId"] = run.id
            event["runStatus"] = str(run.status)
            if run.duration_ms is not None:
                event["durationMs"] = run.duration_ms
        headers = {"content-type": "application/json", "api-key": self._api_key}
        post(self._http, "New Relic", self._url, headers, _js.dumps([event]), [self._api_key])
