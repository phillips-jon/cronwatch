"""Rollbar. API reference: https://docs.rollbar.com/reference/create-item
POST https://api.rollbar.com/api/1/item/ with X-Rollbar-Access-Token
(alerts/rollbar.ts)."""

from __future__ import annotations

import math
from collections.abc import Callable
from typing import Any

from .. import _js
from ..types import Alert, details_to_json
from ._http import HTTP
from ._shared import alert_id, as_uuid, cut, http_or_default, link_for, post, present, required, run_summary, severity

ENDPOINT = "https://api.rollbar.com/api/1/item/"


class Rollbar:
    """Reports alerts to Rollbar, one item per job and alert type.
    ``access_token`` is a project access token with the post_server_item
    scope. Recoveries go too, as info items, unless ``recovered=False``."""

    name = "rollbar"

    def __init__(
        self,
        *,
        access_token: str,
        environment: str | None = None,
        recovered: bool = True,
        link: Callable[[Alert], Any] | None = None,
        http: HTTP | None = None,
    ) -> None:
        # A pasted credential often carries a stray space or newline, which a header would refuse or send.
        self._access_token = required(access_token, "Rollbar() needs an access_token")
        self._environment = environment
        self._recovered = recovered
        self._link = link
        self._http = http_or_default(http)

    def send(self, alert: Alert, context: Any = None) -> None:
        if str(alert.type) == "recovered" and self._recovered is False:
            return
        link = link_for(self._link, alert)
        custom: dict[str, Any] = {"job": alert.job, "type": str(alert.type)}
        if present(alert.triage):
            custom["triage"] = alert.triage
        if link:
            custom["link"] = link
        custom["details"] = details_to_json(alert.details)
        custom["run"] = run_summary(alert)
        item = {
            "data": {
                "environment": cut("production" if self._environment is None else self._environment, 255),
                "level": severity(alert.type),
                "timestamp": math.floor(alert.at / 1000),
                "title": cut(alert.title, 255),
                # Rollbar hashes a fingerprint longer than 40 characters itself.
                "fingerprint": f"cronwatch:{alert.job}:{alert.type}",
                "uuid": as_uuid(alert_id(alert)),
                "body": {"message": {"body": alert.message}},
                "custom": custom,
                "notifier": {"name": "cronwatch"},
            }
        }
        headers = {"content-type": "application/json", "x-rollbar-access-token": self._access_token}
        post(self._http, "Rollbar", ENDPOINT, headers, _js.dumps(item), [self._access_token])
