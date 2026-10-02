import type { Alert, AlertChannel } from "../types.js";
import { cut, postable } from "./shared.js";

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
  under_floor: 0xb7791f,
  recovered: 0x1f8a4c,
};

const TIMEOUT_MS = 10_000;

/** The longest embed description Discord takes. The title (under 256) and it stay well inside the embed's 6000. */
export const DESCRIPTION_MAX = 4096;

/** Sends alerts to a Discord channel through a webhook. */
export function discord(options: DiscordOptions): AlertChannel {
  if (!options.webhookUrl) throw new Error("discord() needs a webhookUrl");
  return {
    name: "discord",
    async send(alert) {
      const url = options.link?.(alert);
      const response = await fetch(postable(options.webhookUrl), {
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
              description: embedDescription(alert),
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

/**
 * The message in a code block, then the triage. Each part has its own cap,
 * and escaping can grow both, so the whole is held to DESCRIPTION_MAX (in
 * UTF-16 units) by cutting the message's block, never the triage: Discord
 * refuses a longer one on every retry.
 */
export function embedDescription(alert: Alert): string {
  const triage = alert.triage ? `\n**Triage:** ${escapeMarkdown(alert.triage.slice(0, 1000))}` : "";
  const fences = "```\n".length + "\n```".length;
  return "```\n" + cut(codeBlockSafe(alert.message.slice(0, 3800)), DESCRIPTION_MAX - fences - triage.length) + "\n```" + triage;
}

/** Breaks up ``` so text inside a code block cannot close it. */
export function codeBlockSafe(text: string): string {
  return text.replace(/```/g, "`​`​`");
}

/** Escapes the characters Discord reads as markdown, links included. */
export function escapeMarkdown(text: string): string {
  return text.replace(/[\\`*_~|[\]()<>]/g, "\\$&");
}
