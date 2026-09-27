/**
 * Resend. API reference: https://resend.com/docs/api-reference/emails/send-email
 * POST https://api.resend.com/emails with a bearer API key.
 */
import type { AlertChannel } from "../types.js";
import { composeEmail, recipients, type EmailOptions } from "./email.js";
import { alertId, post } from "./shared.js";

export interface ResendOptions extends EmailOptions {
  /** An API key from resend.com/api-keys, "re_...". */
  apiKey: string;
}

const ENDPOINT = "https://api.resend.com/emails";

/** Sends alerts as email through Resend. */
export function resend(options: ResendOptions): AlertChannel {
  if (!options.apiKey) throw new Error("resend() needs an apiKey");
  const to = recipients("resend", options);
  return {
    name: "resend",
    async send(alert) {
      const email = composeEmail(alert, options, to);
      await post("Resend", ENDPOINT, {
        headers: {
          "content-type": "application/json",
          authorization: `Bearer ${options.apiKey}`,
          // The same alert sent twice within 24 hours is delivered once.
          "idempotency-key": `cronwatch-${await alertId(alert)}`,
        },
        body: JSON.stringify({ from: email.from, to: email.to, subject: email.subject, text: email.text, html: email.html }),
      }, [options.apiKey]);
    },
  };
}
