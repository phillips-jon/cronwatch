"""SendGrid. API reference: https://www.twilio.com/docs/sendgrid/api-reference/mail-send/mail-send
POST https://api.sendgrid.com/v3/mail/send (api.eu.sendgrid.com for EU
subusers) with a bearer API key. Answers 202 (alerts/sendgrid.ts)."""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

from .. import _js
from ..types import Alert
from ._http import HTTP
from ._shared import http_or_default, post, required
from ._email import compose, parse_address, recipients

__all__ = ["Sendgrid"]


class Sendgrid:
    """Sends alerts as email through SendGrid. ``api_key`` needs Mail Send
    access; ``region="eu"`` for an EU regional subuser."""

    name = "sendgrid"

    def __init__(
        self,
        *,
        api_key: str,
        from_: str,
        to: str | list[str],
        region: str | None = None,
        subject_prefix: str | None = None,
        link: Callable[[Alert], Any] | None = None,
        http: HTTP | None = None,
    ) -> None:
        # A pasted credential often carries a stray space or newline, which a header would refuse or send.
        self._api_key = required(api_key, "Sendgrid() needs an api_key")
        self._to = recipients("Sendgrid", from_, to)
        self._from = from_
        self._url = "https://api.eu.sendgrid.com/v3/mail/send" if region == "eu" else "https://api.sendgrid.com/v3/mail/send"
        self._subject_prefix = subject_prefix
        self._link = link
        self._http = http_or_default(http)

    def send(self, alert: Alert, context: Any = None) -> None:
        email = compose(alert, from_=self._from, to=self._to, subject_prefix=self._subject_prefix, link=self._link)
        body = {
            "personalizations": [{"to": [parse_address(a) for a in email.to]}],
            "from": parse_address(email.from_),
            "subject": email.subject,
            # text/plain must come before text/html.
            "content": [{"type": "text/plain", "value": email.text}, {"type": "text/html", "value": email.html}],
            "categories": ["cronwatch"],
        }
        headers = {"content-type": "application/json", "authorization": f"Bearer {self._api_key}"}
        post(self._http, "SendGrid", self._url, headers, _js.dumps(body), [self._api_key])
