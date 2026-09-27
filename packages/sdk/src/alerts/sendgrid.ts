/**
 * SendGrid. API reference: https://www.twilio.com/docs/sendgrid/api-reference/mail-send/mail-send
 * POST https://api.sendgrid.com/v3/mail/send (api.eu.sendgrid.com for EU
 * subusers) with a bearer API key. Answers 202.
 */
import type { AlertChannel } from "../types.js";
import { composeEmail, parseAddress, recipients, type EmailOptions } from "./email.js";
import { post, trimmed } from "./shared.js";

export interface SendgridOptions extends EmailOptions {
  /** An API key with Mail Send access, "SG...". */
  apiKey: string;
  /** "eu" for an EU regional subuser. Defaults to "us". */
  region?: "us" | "eu";
}

/** Sends alerts as email through SendGrid. */
export function sendgrid(options: SendgridOptions): AlertChannel {
  // A pasted credential often carries a stray space or newline, which a header would refuse or send.
  const apiKey = trimmed(options.apiKey);
  if (!apiKey) throw new Error("sendgrid() needs an apiKey");
  const to = recipients("sendgrid", options);
  const url = options.region === "eu" ? "https://api.eu.sendgrid.com/v3/mail/send" : "https://api.sendgrid.com/v3/mail/send";
  return {
    name: "sendgrid",
    async send(alert) {
      const email = composeEmail(alert, options, to);
      await post("SendGrid", url, {
        headers: { "content-type": "application/json", authorization: `Bearer ${apiKey}` },
        body: JSON.stringify({
          personalizations: [{ to: email.to.map(parseAddress) }],
          from: parseAddress(email.from),
          subject: email.subject,
          // text/plain must come before text/html.
          content: [
            { type: "text/plain", value: email.text },
            { type: "text/html", value: email.html },
          ],
          categories: ["cronwatch"],
        }),
      }, [apiKey]);
    },
  };
}
