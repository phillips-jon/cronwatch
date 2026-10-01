"""Honeybadger, as error notices (not Check-ins, a separate product).
API reference: https://docs.honeybadger.io/api/reporting-exceptions/
POST https://api.honeybadger.io/v1/notices with X-API-Key. Answers 201
(alerts/honeybadger.ts)."""

from __future__ import annotations

import re
from collections.abc import Callable
from typing import Any

from .. import _js
from .._deprecated import names as _deprecated_names
from ..types import Alert, _details_to_json
from ._http import HTTP
from ._shared import cut, http_or_default, link_for, post, present, required, run_summary

__all__ = ["Honeybadger"]

_CLASS = {
    "missed": "CronWatch::Missed",
    "failed": "CronWatch::Failed",
    "stuck": "CronWatch::Stuck",
    "slow": "CronWatch::Slow",
    "over_budget": "CronWatch::OverBudget",
    "recovered": "CronWatch::Recovered",
}

_TRAILING_SLASHES = re.compile(r"/+\Z")


class Honeybadger:
    """Reports alerts to Honeybadger as notices, one error per job and alert
    type. ``endpoint`` is another API host, "https://eu-api.honeybadger.io"
    say. Recoveries are not sent unless ``recovered=True``: Honeybadger has no
    levels, so a recovery would read as an error."""

    name = "honeybadger"

    def __init__(
        self,
        *,
        api_key: str,
        environment: str | None = None,
        endpoint: str | None = None,
        recovered: bool = False,
        link: Callable[[Alert], Any] | None = None,
        http: HTTP | None = None,
    ) -> None:
        # A pasted credential often carries a stray space or newline, which a header would refuse or send.
        self._api_key = required(api_key, "Honeybadger() needs an api_key")
        base = "https://api.honeybadger.io" if endpoint is None else str(endpoint)
        self._url = f"{_TRAILING_SLASHES.sub('', base)}/v1/notices"
        self._environment = environment
        self._recovered = recovered
        self._link = link
        self._http = http_or_default(http)

    def send(self, alert: Alert, context: Any = None) -> None:
        if str(alert.type) == "recovered" and not self._recovered:
            return
        link = link_for(self._link, alert)
        request: dict[str, Any] = {"component": "cronwatch", "action": alert.job}
        if link:
            request["url"] = link
        details: dict[str, Any] = {"job": alert.job, "type": str(alert.type)}
        if present(alert.triage):
            details["triage"] = alert.triage
        details["details"] = _details_to_json(alert.details)
        details["run"] = run_summary(alert)
        request["context"] = details
        notice = {
            "notifier": {"name": "cronwatch", "url": "https://cronwatch.dev"},
            "error": {
                "class": _CLASS[str(alert.type)],
                "message": cut(f"{alert.title}\n{alert.message}", 8000),
                # No code ran here; one frame naming the job keeps the notice well formed.
                "backtrace": [{"number": "0", "file": f"cronwatch/{alert.job}", "method": str(alert.type)}],
                "fingerprint": f"cronwatch:{alert.job}:{alert.type}",
                "tags": ["cronwatch", str(alert.type)],
            },
            "request": request,
            "server": {"environment_name": "production" if self._environment is None else self._environment},
        }
        headers = {"content-type": "application/json", "accept": "application/json", "x-api-key": self._api_key}
        post(self._http, "Honeybadger", self._url, headers, _js.dumps(notice), [self._api_key])


#: Names 1.0 made internal, still answering under their old names (each
#: warning, until 2.0).
__getattr__ = _deprecated_names(__name__, globals(), {"CLASS": "_CLASS"})
