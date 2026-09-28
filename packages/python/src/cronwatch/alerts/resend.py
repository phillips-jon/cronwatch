"""Resend. API reference: https://resend.com/docs/api-reference/emails/send-email
POST https://api.resend.com/emails with a bearer API key (alerts/resend.ts)."""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

from .. import _js
from ..types import Alert
from ._http import HTTP
from ._shared import alert_id, http_or_default, post, required
from .email import compose, recipients

ENDPOINT = "https://api.resend.com/emails"


class Resend:
    """Sends alerts as email through Resend::

        Resend(api_key=os.environ["RESEND_API_KEY"], from_="alerts@example.com", to="ops@example.com")
    """

    name = "resend"

    def __init__(
        self,
        *,
        api_key: str,
        from_: str,
        to: str | list[str],
        subject_prefix: str | None = None,
        link: Callable[[Alert], Any] | None = None,
        http: HTTP | None = None,
    ) -> None:
        # A pasted credential often carries a stray space or newline, which a header would refuse or send.
        self._api_key = required(api_key, "Resend() needs an api_key")
        self._to = recipients("Resend", from_, to)
        self._from = from_
        self._subject_prefix = subject_prefix
        self._link = link
        self._http = http_or_default(http)

    def send(self, alert: Alert, context: Any = None) -> None:
        email = compose(alert, from_=self._from, to=self._to, subject_prefix=self._subject_prefix, link=self._link)
        headers = {
            "content-type": "application/json",
            "authorization": f"Bearer {self._api_key}",
            # The same alert sent twice within 24 hours is delivered once.
            "idempotency-key": f"cronwatch-{alert_id(alert)}",
        }
        body = {"from": email.from_, "to": email.to, "subject": email.subject, "text": email.text, "html": email.html}
        post(self._http, "Resend", ENDPOINT, headers, _js.dumps(body), [self._api_key])
