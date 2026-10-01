"""Bugsnag, Error Reporting API, payload version 5 (alerts/bugsnag.ts).
API reference: https://developer.smartbear.com/bugsnag/docs/reporting-events-and-sessions
POST https://notify.bugsnag.com/ with Bugsnag-Api-Key."""

from __future__ import annotations

import time
from collections.abc import Callable
from typing import Any

from .. import _js
from ..types import Alert, _details_to_json
from ._http import HTTP
from ._shared import cut, http_or_default, iso, link_for, post, present, required, run_summary, severity

__all__ = ["Bugsnag"]


class Bugsnag:
    """Reports alerts to Bugsnag, grouped per job and alert type. ``endpoint``
    is another notify endpoint, for on-premise installs. Recoveries are not
    sent unless ``recovered=True``, since each one is an event on an error.
    ``now`` is the clock for the Bugsnag-Sent-At header, in epoch
    milliseconds, for tests."""

    name = "bugsnag"

    def __init__(
        self,
        *,
        api_key: str,
        release_stage: str | None = None,
        endpoint: str | None = None,
        recovered: bool = False,
        now: Callable[[], int] | None = None,
        link: Callable[[Alert], Any] | None = None,
        http: HTTP | None = None,
    ) -> None:
        # A pasted credential often carries a stray space or newline, which a header would refuse or send.
        self._api_key = required(api_key, "Bugsnag() needs an api_key")
        self._url = "https://notify.bugsnag.com/" if endpoint is None else str(endpoint)
        self._release_stage = release_stage
        self._recovered = recovered
        self._now = now or (lambda: time.time_ns() // 1_000_000)
        self._link = link
        self._http = http_or_default(http)

    def send(self, alert: Alert, context: Any = None) -> None:
        if str(alert.type) == "recovered" and not self._recovered:
            return
        link = link_for(self._link, alert)
        meta: dict[str, Any] = {"job": alert.job, "type": str(alert.type)}
        if present(alert.triage):
            meta["triage"] = alert.triage
        if link:
            meta["link"] = link
        meta["details"] = _details_to_json(alert.details)
        meta["run"] = run_summary(alert)
        payload = {
            "apiKey": self._api_key,
            "payloadVersion": "5",
            # The notifier's own version, not the package's; Bugsnag asks for one.
            "notifier": {"name": "cronwatch", "version": "1.0.0", "url": "https://cronwatch.dev"},
            "events": [
                {
                    "exceptions": [
                        {"errorClass": f"CronWatch {alert.type}", "message": cut(f"{alert.title}\n{alert.message}", 8000), "stacktrace": [], "type": "nodejs"}
                    ],
                    "severity": severity(alert.type),
                    "unhandled": False,
                    "severityReason": {"type": "handledException"},
                    "context": alert.job,
                    "groupingHash": f"cronwatch:{alert.job}:{alert.type}",
                    "metaData": {"cronwatch": meta},
                    "app": {"releaseStage": "production" if self._release_stage is None else self._release_stage},
                    "device": {"time": iso(alert.at)},
                }
            ],
        }
        headers = {
            "content-type": "application/json",
            "bugsnag-api-key": self._api_key,
            "bugsnag-payload-version": "5",
            "bugsnag-sent-at": iso(self._now()),
        }
        post(self._http, "Bugsnag", self._url, headers, _js.dumps(payload), [self._api_key])
