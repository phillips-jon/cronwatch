"""Discord, through a channel webhook (alerts/discord.ts)."""

from __future__ import annotations

import re
from collections.abc import Callable
from typing import Any

from .. import _js
from ..types import Alert
from ._http import HTTP
from ._shared import http_or_default, iso, link_for, present, slice16

COLOR = {
    "missed": 0xB7791F,
    "failed": 0xC62828,
    "stuck": 0xC62828,
    "slow": 0xB7791F,
    "over_budget": 0xB7791F,
    "recovered": 0x1F8A4C,
}

_MARKDOWN = re.compile(r"[\\`*_~|\[\]()<>]")


class Discord:
    """Sends alerts to a Discord channel through a webhook (Server Settings,
    Integrations, Webhooks)."""

    name = "discord"

    def __init__(self, webhook_url: str, *, link: Callable[[Alert], Any] | None = None, http: HTTP | None = None) -> None:
        if not present(webhook_url):
            raise ValueError("Discord() needs a webhook_url")
        self._webhook_url = str(webhook_url)
        self._link = link
        self._http = http_or_default(http)

    def send(self, alert: Alert, context: Any = None) -> None:
        url = link_for(self._link, alert)
        embed: dict[str, Any] = {"title": alert.title}
        if url:
            embed["url"] = url
        triage = f"\n**Triage:** {escape_markdown(slice16(str(alert.triage), 1000))}" if present(alert.triage) else ""
        embed["description"] = "```\n" + code_block_safe(slice16(alert.message, 3800)) + "\n```" + triage
        embed["color"] = COLOR[str(alert.type)]
        embed["timestamp"] = iso(alert.at)
        payload = {
            "content": alert.title,
            # Job output can hold anything, "@everyone" included; ping no one.
            "allowed_mentions": {"parse": []},
            "embeds": [embed],
        }
        # Refused, not followed: a webhook URL is its own credential.
        response = self._http.post(self._webhook_url, _js.dumps(payload), {"content-type": "application/json"})
        if not response.ok:
            raise RuntimeError(f"Discord webhook answered {response.status}: {_js.head16(response.body or '', 200)}")


def code_block_safe(text: str) -> str:
    """Breaks up ``` so text inside a code block cannot close it."""
    return text.replace("```", "`​`​`")


def escape_markdown(text: str) -> str:
    """Escapes the characters Discord reads as markdown, links included."""
    return _MARKDOWN.sub(lambda m: "\\" + m.group(0), text)
