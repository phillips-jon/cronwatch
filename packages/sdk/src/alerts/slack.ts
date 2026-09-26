import type { Alert, AlertChannel } from "../types.js";

export interface SlackOptions {
  /** An incoming webhook URL from api.slack.com/messaging/webhooks. */
  webhookUrl: string;
  /** Link back to the job in your dashboard: (alert) => `https://app.example.com/cronwatch/jobs/${alert.job}`. */
  link?: (alert: Alert) => string;
}

const EMOJI: Record<Alert["type"], string> = {
  missed: ":hourglass_flowing_sand:",
  failed: ":x:",
  stuck: ":no_entry:",
  slow: ":turtle:",
  over_budget: ":moneybag:",
  recovered: ":white_check_mark:",
};

/** Sends alerts to a Slack channel through an incoming webhook. */
export function slack(options: SlackOptions): AlertChannel {
  if (!options.webhookUrl) throw new Error("slack() needs a webhookUrl");
  return {
    name: "slack",
    async send(alert) {
      const url = options.link?.(alert);
      const title = `${EMOJI[alert.type]} *${escape(alert.title)}*${url ? ` (<${url}|open>)` : ""}`;
      const body = escape(alert.message);
      const triage = alert.triage ? `\n_Triage:_ ${escape(alert.triage)}` : "";
      const response = await fetch(options.webhookUrl, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          text: `${alert.title}\n${alert.message}`,
          blocks: [
            { type: "section", text: { type: "mrkdwn", text: title } },
            { type: "section", text: { type: "mrkdwn", text: "```" + body.slice(0, 2800) + "```" + triage } },
          ],
        }),
      });
      if (!response.ok) throw new Error(`Slack webhook answered ${response.status}: ${(await response.text()).slice(0, 200)}`);
    },
  };
}

function escape(text: string): string {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}
