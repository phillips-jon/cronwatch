import type { Alert, AlertChannel } from "../types.js";

export interface DiscordOptions {
  /** A channel webhook URL from Server Settings, Integrations, Webhooks. */
  webhookUrl: string;
  link?: (alert: Alert) => string;
}

const COLOR: Record<Alert["type"], number> = {
  missed: 0xb7791f,
  failed: 0xc62828,
  stuck: 0xc62828,
  slow: 0xb7791f,
  over_budget: 0xb7791f,
  recovered: 0x1f8a4c,
};

const TIMEOUT_MS = 10_000;

/** Sends alerts to a Discord channel through a webhook. */
export function discord(options: DiscordOptions): AlertChannel {
  if (!options.webhookUrl) throw new Error("discord() needs a webhookUrl");
  return {
    name: "discord",
    async send(alert) {
      const url = options.link?.(alert);
      const response = await fetch(options.webhookUrl, {
        method: "POST",
        headers: { "content-type": "application/json" },
        // Refused, not followed: a webhook URL is its own credential.
        redirect: "error",
        signal: AbortSignal.timeout(TIMEOUT_MS),
        body: JSON.stringify({
          content: alert.title,
          // Job output can hold anything, "@everyone" included; ping no one.
          allowed_mentions: { parse: [] },
          embeds: [
            {
              title: alert.title,
              ...(url ? { url } : {}),
              description: "```\n" + codeBlockSafe(alert.message.slice(0, 3800)) + "\n```" + (alert.triage ? `\n**Triage:** ${escapeMarkdown(alert.triage.slice(0, 1000))}` : ""),
              color: COLOR[alert.type],
              timestamp: new Date(alert.at).toISOString(),
            },
          ],
        }),
      });
      if (!response.ok) throw new Error(`Discord webhook answered ${response.status}: ${(await response.text()).slice(0, 200)}`);
    },
  };
}

/** Breaks up ``` so text inside a code block cannot close it. */
export function codeBlockSafe(text: string): string {
  return text.replace(/```/g, "`​`​`");
}

/** Escapes the characters Discord reads as markdown, links included. */
export function escapeMarkdown(text: string): string {
  return text.replace(/[\\`*_~|[\]()<>]/g, "\\$&");
}
