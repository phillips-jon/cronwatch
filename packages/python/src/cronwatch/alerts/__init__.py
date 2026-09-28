"""Alert channels. A channel is an object with a ``name`` and a
``send(alert, context)`` method that returns once the alert went out (to at
least one recipient) and raises when it went nowhere; ``context.on_error(e)``
reports a problem that did not stop the alert (one of several recipients
refusing it). A ``send`` that takes only the alert is called with the alert
alone, and a plain function works as a channel too.

``Console`` (the default) and ``Custom`` are here, with the SDK's channels,
request for request: ``Slack``, ``Discord``, ``Webhook``, the email
providers ``Resend``, ``Postmark``, ``Sendgrid``, ``Mailgun`` and ``Ses``,
``Twilio`` for SMS, and the trackers ``Sentry``, ``Honeybadger``,
``Datadog``, ``Rollbar``, ``Bugsnag`` and ``NewRelic``. They use the
standard library only, and each takes ``http=`` (anything with
``post(url, body, headers)`` returning a ``Response``) so tests can stand in
for the network."""

from __future__ import annotations

import inspect
import sys
from collections.abc import Callable
from typing import Any, Protocol, runtime_checkable

from ..types import Alert, AlertType


class ChannelContext:
    """What the client hands a channel with each alert."""

    def __init__(self, on_error: Callable[[BaseException], None]) -> None:
        self._on_error = on_error

    def on_error(self, error: BaseException) -> None:
        """Report a problem that did not stop the alert going out, such as one of
        several recipients refusing it. Goes to the client's on_error."""
        self._on_error(error)


@runtime_checkable
class AlertChannel(Protocol):
    name: str

    def send(self, alert: Alert, context: ChannelContext) -> None: ...


class Console:
    """Writes alerts to the terminal: problems to stderr, recoveries to stdout. The default channel."""

    name = "console"

    def send(self, alert: Alert, context: ChannelContext | None = None) -> None:
        line = f"[cronwatch] {alert.title}\n{alert.message}" + (f"\nTriage: {alert.triage}" if alert.triage else "")
        stream = sys.stdout if alert.type == AlertType.RECOVERED else sys.stderr
        print(line, file=stream, flush=True)


class Custom:
    """Wraps any function as an alert channel: ``Custom("pager", lambda alert: page(alert.title))``."""

    def __init__(self, name: str, send: Callable[..., Any]) -> None:
        self.name = name
        self._send = send

    def send(self, alert: Alert, context: ChannelContext | None = None) -> None:
        if context is not None and takes_context(self._send):
            self._send(alert, context)
        else:
            self._send(alert)


def takes_context(fn: Callable[..., Any]) -> bool:
    """Whether a function accepts a second positional argument (the context)."""
    try:
        parameters = inspect.signature(fn).parameters.values()
    except (TypeError, ValueError):
        return True
    positional = 0
    for p in parameters:
        if p.kind == p.VAR_POSITIONAL:
            return True
        if p.kind in (p.POSITIONAL_ONLY, p.POSITIONAL_OR_KEYWORD):
            positional += 1
    return positional >= 2


def channel_name(channel: Any) -> str:
    name = getattr(channel, "name", None)
    if isinstance(name, str) and name:
        return name
    return getattr(channel, "__name__", None) or type(channel).__name__


def send_to(channel: Any, alert: Alert, context: ChannelContext) -> None:
    """channel.send(alert, context), or channel(alert, context) for a plain
    function; either with the alert alone when it takes only that."""
    send = getattr(channel, "send", None)
    target = send if callable(send) else channel
    if not callable(target):
        raise TypeError(f"alert channel {channel_name(channel)} has no send(alert, context)")
    if takes_context(target):
        target(alert, context)
    else:
        target(alert)


# The channels, imported last: each module imports the helpers above it.
from ._http import RequestTimeout, Response, UrllibHTTP  # noqa: E402
from .bugsnag import Bugsnag  # noqa: E402
from .datadog import Datadog  # noqa: E402
from .discord import Discord  # noqa: E402
from .honeybadger import Honeybadger  # noqa: E402
from .mailgun import Mailgun  # noqa: E402
from .newrelic import NewRelic  # noqa: E402
from .postmark import Postmark  # noqa: E402
from .resend import Resend  # noqa: E402
from .rollbar import Rollbar  # noqa: E402
from .sendgrid import Sendgrid  # noqa: E402
from .sentry import Sentry  # noqa: E402
from .ses import Ses  # noqa: E402
from .slack import Slack  # noqa: E402
from .twilio import Twilio  # noqa: E402
from .webhook import Webhook  # noqa: E402

__all__ = [
    "AlertChannel",
    "Bugsnag",
    "ChannelContext",
    "Console",
    "Custom",
    "Datadog",
    "Discord",
    "Honeybadger",
    "Mailgun",
    "NewRelic",
    "Postmark",
    "RequestTimeout",
    "Resend",
    "Response",
    "Rollbar",
    "Sendgrid",
    "Sentry",
    "Ses",
    "Slack",
    "Twilio",
    "UrllibHTTP",
    "Webhook",
]
