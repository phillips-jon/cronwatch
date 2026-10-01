"""Mailgun. API reference: https://documentation.mailgun.com/docs/mailgun/api-reference/send/mailgun/messages
POST https://api.mailgun.net/v3/<domain>/messages (api.eu.mailgun.net for the
EU region), form encoded, with basic auth "api:<key>" (alerts/mailgun.ts)."""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

from ..types import Alert
from ._http import HTTP
from ._shared import basic_auth, encode_uri_component, form, http_or_default, post, present, required
from ._email import compose, recipients

__all__ = ["Mailgun"]


class Mailgun:
    """Sends alerts as email through Mailgun. ``domain`` is the sending
    domain, "mg.example.com"; ``region="eu"`` for a domain in the EU region."""

    name = "mailgun"

    def __init__(
        self,
        *,
        api_key: str,
        domain: str,
        from_: str,
        to: str | list[str],
        region: str | None = None,
        subject_prefix: str | None = None,
        link: Callable[[Alert], Any] | None = None,
        http: HTTP | None = None,
    ) -> None:
        # A pasted credential often carries a stray space or newline, which a header would refuse or send.
        self._api_key = required(api_key, "Mailgun() needs an api_key")
        if not present(domain):
            raise ValueError("Mailgun() needs a domain")
        self._to = recipients("Mailgun", from_, to)
        self._from = from_
        host = "https://api.eu.mailgun.net" if region == "eu" else "https://api.mailgun.net"
        self._url = f"{host}/v3/{encode_uri_component(str(domain))}/messages"
        self._subject_prefix = subject_prefix
        self._link = link
        self._http = http_or_default(http)

    def send(self, alert: Alert, context: Any = None) -> None:
        email = compose(alert, from_=self._from, to=self._to, subject_prefix=self._subject_prefix, link=self._link)
        pairs = [("from", email.from_), *(("to", address) for address in email.to)]
        pairs += [("subject", email.subject), ("text", email.text), ("html", email.html), ("o:tag", "cronwatch")]
        headers = {"content-type": "application/x-www-form-urlencoded", "authorization": basic_auth("api", self._api_key)}
        post(self._http, "Mailgun", self._url, headers, form(pairs), [self._api_key])
