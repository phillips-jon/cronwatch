"""Postmark. API reference: https://postmarkapp.com/developer/api/email-api
POST https://api.postmarkapp.com/email with X-Postmark-Server-Token (alerts/postmark.ts)."""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

from .. import _js
from ..types import Alert
from ._http import HTTP
from ._shared import http_or_default, post, required
from .email import compose, recipients

ENDPOINT = "https://api.postmarkapp.com/email"


class Postmark:
    """Sends alerts as email through Postmark. ``server_token`` is a server
    API token, from the server's API Tokens tab; ``message_stream`` defaults
    to "outbound", the transactional stream."""

    name = "postmark"

    def __init__(
        self,
        *,
        server_token: str,
        from_: str,
        to: str | list[str],
        message_stream: str | None = None,
        subject_prefix: str | None = None,
        link: Callable[[Alert], Any] | None = None,
        http: HTTP | None = None,
    ) -> None:
        # A pasted credential often carries a stray space or newline, which a header would refuse or send.
        self._server_token = required(server_token, "Postmark() needs a server_token")
        self._to = recipients("Postmark", from_, to)
        self._from = from_
        self._message_stream = message_stream
        self._subject_prefix = subject_prefix
        self._link = link
        self._http = http_or_default(http)

    def send(self, alert: Alert, context: Any = None) -> None:
        email = compose(alert, from_=self._from, to=self._to, subject_prefix=self._subject_prefix, link=self._link)
        headers = {"content-type": "application/json", "accept": "application/json", "x-postmark-server-token": self._server_token}
        body = {
            "From": email.from_,
            "To": ", ".join(email.to),
            "Subject": email.subject,
            "TextBody": email.text,
            "HtmlBody": email.html,
            "MessageStream": "outbound" if self._message_stream is None else self._message_stream,
            "Tag": "cronwatch",
        }
        post(self._http, "Postmark", ENDPOINT, headers, _js.dumps(body), [self._server_token])
