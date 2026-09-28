"""Twilio SMS. API reference: https://www.twilio.com/docs/messaging/api/message-resource
POST https://api.twilio.com/2010-04-01/Accounts/<AccountSid>/Messages.json,
form encoded, with basic auth. One recipient per request (alerts/twilio.ts)."""

from __future__ import annotations

import math
import sys
import threading
import time
from collections.abc import Callable
from typing import Any

from .. import _js
from ..types import Alert
from ._http import HTTP, TIMEOUT, RequestTimeout
from ._shared import basic_auth, cut, encode_uri_component, form, http_or_default, link_for, post, present, required, trimmed

#: The most segments a message may use, which keeps it inside Twilio's 1600 character Body limit.
MAX_SEGMENTS = 10
#: Twilio refuses a Body longer than this.
MAX_BODY = 1600

# The GSM 03.38 alphabet: a message in it takes 153 characters a segment
# (when split), anything else is UCS-2 at 67. The extension table costs two.
GSM = frozenset("@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !\"#¤%&'()*+,-./0123456789:;<=>?¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà")
GSM_EXTENDED = frozenset("^{}\\[~]|€\f")


class Twilio:
    """Texts alerts through Twilio, to every number at once::

        Twilio(account_sid=os.environ["TWILIO_ACCOUNT_SID"], auth_token=os.environ["TWILIO_AUTH_TOKEN"],
               from_="+15005550006", to=["+15551110000"])

    Sign with ``auth_token``, or with ``api_key_sid`` and ``api_key_secret``
    (each trimmed of the spaces and newlines a paste leaves). Send from a
    number, or through ``messaging_service_sid``. Recoveries are not texted
    unless ``recovered=True``: a text is for what needs a person. A message
    fits in ``segments`` SMS segments (default 3, 1 to 10).

    The alert counts as delivered when any number took it; each number that
    refused it is reported through the client's channel context
    (``on_error``). It fails only when every number did."""

    name = "twilio"

    def __init__(
        self,
        *,
        account_sid: str,
        to: str | list[str],
        auth_token: str | None = None,
        api_key_sid: str | None = None,
        api_key_secret: str | None = None,
        from_: str | None = None,
        messaging_service_sid: str | None = None,
        recovered: bool = False,
        segments: Any = 3,
        link: Callable[[Alert], Any] | None = None,
        http: HTTP | None = None,
    ) -> None:
        # A pasted credential often carries a stray space or newline, which the Authorization header would refuse or send.
        account_sid = required(account_sid, "Twilio() needs an account_sid")
        key_sid = trimmed(api_key_sid)
        user = key_sid or account_sid
        password = trimmed(api_key_secret) if key_sid else trimmed(auth_token)
        if not password:
            raise ValueError("Twilio() needs an auth_token, or an api_key_sid and api_key_secret")
        if not present(from_) and not present(messaging_service_sid):
            raise ValueError("Twilio() needs a from number or a messaging_service_sid")
        listed = to if isinstance(to, (list, tuple)) else [to]
        self._to = [_js.trim(n) for n in listed if isinstance(n, str) and _js.trim(n) != ""]
        if not self._to:
            raise ValueError("Twilio() needs at least one to number")
        self._url = f"https://api.twilio.com/2010-04-01/Accounts/{encode_uri_component(account_sid)}/Messages.json"
        self._password = password
        self._authorization = basic_auth(user, password)
        self._from = from_
        self._messaging_service_sid = messaging_service_sid
        self._recovered = recovered
        self._segments = segment_budget(segments)
        self._link = link
        self._http = http_or_default(http)
        # How long to wait for the numbers' requests, each already bounded by its own HTTP deadline.
        self._deadline_s = TIMEOUT + 1

    def send(self, alert: Alert, context: Any = None) -> None:
        """``context`` is the client's channel context: each number that refused
        the alert, when another took it, is reported through its on_error."""
        if str(alert.type) == "recovered" and not self._recovered:
            return
        body = sms_body(alert, link_for(self._link, alert), self._segments)
        errors = self._send_all(body)
        failed = [(self._to[i], error) for i, error in enumerate(errors) if error is not None]
        if not failed:
            return
        if len(failed) == len(self._to):
            message = str(failed[0][1])
            raise RuntimeError(f"{message} ({len(failed)} of {len(self._to)} numbers failed)" if len(self._to) > 1 else message)
        # Delivered to someone: counted as sent, so a retry never texts the numbers that took it again.
        took = len(self._to) - len(failed)
        for number, error in failed:
            report = RuntimeError(f"{error} (to {mask_number(number)}; {took} of {len(self._to)} numbers took the alert)")
            on_error = getattr(context, "on_error", None)
            if callable(on_error):
                on_error(report)
            else:
                print(f"[cronwatch] alert channel twilio: {report}", file=sys.stderr, flush=True)

    def _send_all(self, body: str) -> list[BaseException | None]:
        """Posts to every number at once, each in its own thread. Returns the
        error for each number, by index, or None where it took the alert."""
        errors: list[BaseException | None] = [None] * len(self._to)
        done = [False] * len(self._to)

        def send(i: int, number: str) -> None:
            pairs = [("To", number)]
            if present(self._messaging_service_sid):
                pairs.append(("MessagingServiceSid", str(self._messaging_service_sid)))
            else:
                pairs.append(("From", str(self._from)))
            pairs.append(("Body", body))
            headers = {"content-type": "application/x-www-form-urlencoded", "authorization": self._authorization}
            try:
                post(self._http, "Twilio", self._url, headers, form(pairs), [self._password])
            except Exception as error:  # each number's failure is kept, never raised here
                errors[i] = error
            done[i] = True

        threads = [threading.Thread(target=send, args=(i, n), name=f"cronwatch-twilio-{i}", daemon=True) for i, n in enumerate(self._to)]
        for thread in threads:
            thread.start()
        deadline = time.monotonic() + self._deadline_s
        for i, thread in enumerate(threads):
            thread.join(max(deadline - time.monotonic(), 0))
            if not done[i]:
                errors[i] = RequestTimeout()
        return errors


def mask_number(number: str) -> str:
    """A number with all but its last four digits hidden, for an error message."""
    length = _js.length16(number)
    return number if length <= 4 else "*" * min(length - 4, 8) + _js.tail16(number, 4)


def segment_budget(segments: Any) -> int:
    """A segment count clamped to 1 to MAX_SEGMENTS; 3 for anything not a number."""
    n = math.floor(segments) if _js.is_finite(segments) else 3
    return min(MAX_SEGMENTS, max(1, n))


def sms_segments(text: str) -> int:
    """The segments `text` takes. A character is never split across two: an
    extension character (two septets) or a surrogate pair (two UCS-2 units)
    that would straddle a boundary starts the next segment, as phones pack
    them."""
    units: list[int] = []
    gsm = True
    for ch in text:
        if ch in GSM:
            units.append(1)
        elif ch in GSM_EXTENDED:
            units.append(2)
        else:
            gsm = False
            break
    if gsm:
        single, per, sizes = 160, 153, units
    else:
        single, per, sizes = 70, 67, [2 if ord(ch) > 0xFFFF else 1 for ch in text]
    if sum(sizes) <= single:
        return 1
    count = 1
    used = 0
    for u in sizes:
        if used + u > per:
            count += 1
            used = 0
        used += u
    return count


def fits(text: str, segments: int) -> bool:
    """Whether `text` fits in `segments` SMS segments and Twilio's Body limit."""
    return _js.length16(text) <= MAX_BODY and sms_segments(text) <= segments


def sms_body(alert: Alert, link: str | None, segments: Any = 3) -> str:
    """The title, then as many lines of the message (and the triage) as fit,
    then the link. The link is kept whole; the text before it is cut to make
    room. `segments` is clamped to 1 to 10."""
    budget = segment_budget(segments)
    tail = f"\n{link}" if present(link) else ""
    lines = [alert.title, *(line for line in alert.message.split("\n") if _js.trim(line) != "")]
    if present(alert.triage):
        lines.append(f"Triage: {alert.triage}")
    text = ""
    for line in lines:
        following = f"{text}\n{line}" if text else line
        if fits(following + tail, budget):
            text = following
            continue
        # Part of this line, cut on a code point and marked.
        chars = list(line)
        lo, hi = 0, len(chars)
        while lo < hi:
            mid = (lo + hi + 1) // 2
            candidate = (f"{text}\n" if text else "") + "".join(chars[:mid]) + "..."
            if fits(candidate + tail, budget):
                lo = mid
            else:
                hi = mid - 1
        if lo > 0:
            text = (f"{text}\n" if text else "") + "".join(chars[:lo]) + "..."
        break
    # Only a link too long for any budget gets here too long; Twilio would refuse it whole.
    return cut(text + tail, MAX_BODY)
