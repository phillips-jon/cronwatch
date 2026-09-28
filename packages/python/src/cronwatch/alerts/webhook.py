"""Any URL, the alert as JSON (alerts/webhook.ts)."""

from __future__ import annotations

import hashlib
import hmac
from collections.abc import Mapping
from typing import Any

from .. import _js
from ..types import Alert
from ._http import HTTP
from ._shared import http_or_default, origin, present


class Webhook:
    """POSTs the alert as JSON to any URL. The body is the alert's JSON:
    { type, run, details, job, definition, title, message, at, triage }.
    With a secret, each request carries ``X-CronWatch-Signature: sha256=<hex>``,
    the HMAC-SHA256 of the raw body, so the receiver can verify it. Header
    values are trimmed. A redirect is an error, not followed (the headers
    and the signature would go with it): point the url at where the
    receiver really is."""

    name = "webhook"

    def __init__(self, url: str, *, headers: Mapping[str, str] | None = None, secret: str | None = None, http: HTTP | None = None) -> None:
        if not present(url):
            raise ValueError("Webhook() needs a url")
        self._url = str(url)
        self._headers = dict(headers or {})
        self._secret = secret
        self._http = http_or_default(http)

    def send(self, alert: Alert, context: Any = None) -> None:
        body = _js.dumps(alert.to_dict())
        headers = {"content-type": "application/json", "user-agent": "cronwatch"}
        # A pasted Authorization value often carries a stray space or newline, which a header would refuse.
        for name, value in self._headers.items():
            headers[str(name)] = _js.trim(value) if isinstance(value, str) else value
        if self._secret:
            headers["x-cronwatch-signature"] = f"sha256={hmac_sha256_hex(self._secret, body)}"
        response = self._http.post(self._url, body, headers)
        # Only the origin: a webhook URL's path or query often is the credential.
        if not response.ok:
            raise RuntimeError(f"Webhook {origin(self._url)} answered {response.status}")


def hmac_sha256_hex(secret: str, body: str) -> str:
    """HMAC-SHA256 as lowercase hex."""
    return hmac.new(_js.well_formed(secret).encode("utf-8"), _js.well_formed(body).encode("utf-8"), hashlib.sha256).hexdigest()
