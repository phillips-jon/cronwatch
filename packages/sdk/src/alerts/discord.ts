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
        body: JSON.stringify({
          content: alert.title,
          embeds: [
            {
              title: alert.title,
              ...(url ? { url } : {}),
              description: "```\n" + alert.message.slice(0, 3800) + "\n```" + (alert.triage ? `\n**Triage:** ${alert.triage.slice(0, 1000)}` : ""),
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
