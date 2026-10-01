"""Discord, through a channel webhook (alerts/discord.ts)."""

from __future__ import annotations

import re
from collections.abc import Callable
from typing import Any

from .. import _js
from .._deprecated import names as _deprecated_names
from ..types import Alert
from ._http import HTTP
from ._shared import cut, http_or_default, iso, link_for, positional_url, present, slice16

__all__ = ["Discord"]

_COLOR = {
    "missed": 0xB7791F,
    "failed": 0xC62828,
    "stuck": 0xC62828,
    "slow": 0xB7791F,
    "over_budget": 0xB7791F,
    "recovered": 0x1F8A4C,
}

_MARKDOWN = re.compile(r"[\\`*_~|\[\]()<>]")

#: The longest embed description Discord takes. The title (under 256) and it stay well inside the embed's 6000.
_DESCRIPTION_MAX = 4096


class Discord:
    """Sends alerts to a Discord channel through a webhook (Server Settings,
    Integrations, Webhooks)::

        Discord(webhook_url=os.environ["DISCORD_WEBHOOK_URL"])

    The URL is taken by name; ``Discord(url)``, positionally, is deprecated (it
    warns, and goes in 2.0).
    """

    name = "discord"

    def __init__(
        self,
        _url: str | None = None,
        /,
        *,
        webhook_url: str | None = None,
        link: Callable[[Alert], Any] | None = None,
        http: HTTP | None = None,
    ) -> None:
        webhook_url = positional_url("Discord", _url, webhook_url)
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
        embed["description"] = _embed_description(alert)
        embed["color"] = _COLOR[str(alert.type)]
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


def _embed_description(alert: Alert) -> str:
    """The message in a code block, then the triage. Each part has its own
    cap, and escaping can grow both, so the whole is held to DESCRIPTION_MAX
    (in UTF-16 units) by cutting the message's block, never the triage:
    Discord refuses a longer one on every retry."""
    triage = f"\n**Triage:** {_escape_markdown(slice16(str(alert.triage), 1000))}" if present(alert.triage) else ""
    fences = len("```\n") + len("\n```")
    return "```\n" + cut(_code_block_safe(slice16(alert.message, 3800)), _DESCRIPTION_MAX - fences - _js.length16(triage)) + "\n```" + triage


def _code_block_safe(text: str) -> str:
    """Breaks up ``` so text inside a code block cannot close it."""
    return text.replace("```", "`​`​`")


def _escape_markdown(text: str) -> str:
    """Escapes the characters Discord reads as markdown, links included."""
    return _MARKDOWN.sub(lambda m: "\\" + m.group(0), text)


#: Internal names, still answering under their old public names (each
#: warning, until 1.0 removes them).
__getattr__ = _deprecated_names(__name__, globals(), {"COLOR": "_COLOR", "DESCRIPTION_MAX": "_DESCRIPTION_MAX", "embed_description": "_embed_description", "code_block_safe": "_code_block_safe", "escape_markdown": "_escape_markdown"})
