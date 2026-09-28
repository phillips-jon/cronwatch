"""Amazon SES, API v2 SendEmail. API reference: https://docs.aws.amazon.com/ses/latest/APIReference-V2/API_SendEmail.html
POST https://email.<region>.amazonaws.com/v2/email/outbound-emails, signed
with AWS Signature Version 4 (see sigv4.py), so no AWS SDK is needed
(alerts/ses.ts)."""

from __future__ import annotations

import re
import time
from collections.abc import Callable
from typing import Any

from .. import _js
from ..types import Alert
from . import sigv4
from ._http import HTTP
from ._shared import http_or_default, post, present, trimmed
from .email import compose, recipients

_REGION = re.compile(r"^[a-z0-9-]+\Z")


class Ses:
    """Sends alerts as email through Amazon SES. The from identity must be
    verified in ``region``. ``session_token`` is for temporary credentials
    (an assumed role, say); ``now`` is the clock used to sign requests, in
    epoch milliseconds, for tests."""

    name = "ses"

    def __init__(
        self,
        *,
        region: str,
        access_key_id: str,
        secret_access_key: str,
        from_: str,
        to: str | list[str],
        session_token: str | None = None,
        configuration_set_name: str | None = None,
        subject_prefix: str | None = None,
        link: Callable[[Alert], Any] | None = None,
        now: Callable[[], int] | None = None,
        http: HTTP | None = None,
    ) -> None:
        if not present(region):
            raise ValueError("Ses() needs a region")
        if not isinstance(region, str) or not _REGION.search(region):
            raise ValueError("Ses() needs a region like us-east-1")
        # A pasted credential often carries a stray space or newline, which would spoil the signature.
        self._access_key_id = trimmed(access_key_id)
        self._secret_access_key = trimmed(secret_access_key)
        self._session_token = trimmed(session_token) or None
        if not self._access_key_id or not self._secret_access_key:
            raise ValueError("Ses() needs an access_key_id and secret_access_key")
        self._to = recipients("Ses", from_, to)
        self._from = from_
        self._region = region
        self._configuration_set_name = configuration_set_name
        self._subject_prefix = subject_prefix
        self._link = link
        self._now = now or (lambda: time.time_ns() // 1_000_000)
        self._url = f"https://email.{region}.amazonaws.com/v2/email/outbound-emails"
        self._http = http_or_default(http)

    def send(self, alert: Alert, context: Any = None) -> None:
        email = compose(alert, from_=self._from, to=self._to, subject_prefix=self._subject_prefix, link=self._link)
        payload: dict[str, Any] = {
            "FromEmailAddress": email.from_,
            "Destination": {"ToAddresses": email.to},
            "Content": {
                "Simple": {
                    "Subject": {"Data": email.subject, "Charset": "UTF-8"},
                    "Body": {"Text": {"Data": email.text, "Charset": "UTF-8"}, "Html": {"Data": email.html, "Charset": "UTF-8"}},
                },
            },
        }
        if present(self._configuration_set_name):
            payload["ConfigurationSetName"] = self._configuration_set_name
        payload["EmailTags"] = [{"Name": "source", "Value": "cronwatch"}]
        body = _js.dumps(payload)
        headers = sigv4.sign(
            method="POST",
            url=self._url,
            headers={"content-type": "application/json"},
            body=body,
            region=self._region,
            service="ses",
            now=self._now(),
            access_key_id=self._access_key_id,
            secret_access_key=self._secret_access_key,
            session_token=self._session_token,
        )
        post(self._http, "SES", self._url, headers, body, [self._secret_access_key, self._session_token])
