import { createHmac } from "node:crypto";
import type { AlertChannel } from "../types.js";

export interface WebhookOptions {
  url: string;
  /** Extra request headers, for an Authorization header say. */
  headers?: Record<string, string>;
  /**
   * When set, each request carries `X-CronWatch-Signature: sha256=<hex>`,
   * the HMAC-SHA256 of the raw body with this secret, so the receiver can
   * verify it.
   */
  secret?: string;
}

/**
 * POSTs the alert as JSON to any URL. The body is the Alert object:
 * { type, job, title, message, run, details, triage, at, definition }.
 */
export function webhook(options: WebhookOptions): AlertChannel {
  if (!options.url) throw new Error("webhook() needs a url");
  return {
    name: "webhook",
    async send(alert) {
      const body = JSON.stringify(alert);
      const headers: Record<string, string> = { "content-type": "application/json", "user-agent": "cronwatch", ...options.headers };
      if (options.secret) {
        headers["x-cronwatch-signature"] = `sha256=${createHmac("sha256", options.secret).update(body).digest("hex")}`;
      }
      const response = await fetch(options.url, { method: "POST", headers, body });
      if (!response.ok) throw new Error(`Webhook ${options.url} answered ${response.status}`);
    },
  };
}
