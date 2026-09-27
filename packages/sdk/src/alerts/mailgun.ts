/**
 * Mailgun. API reference: https://documentation.mailgun.com/docs/mailgun/api-reference/send/mailgun/messages/post-v3--domain-name--messages
 * POST https://api.mailgun.net/v3/<domain>/messages (api.eu.mailgun.net for
 * the EU region), form encoded, with basic auth "api:<key>".
 */
import type { AlertChannel } from "../types.js";
import { composeEmail, recipients, type EmailOptions } from "./email.js";
import { basicAuth, post, trimmed } from "./shared.js";

export interface MailgunOptions extends EmailOptions {
  /** A sending or account API key. */
  apiKey: string;
  /** The sending domain, "mg.example.com". */
  domain: string;
  /** "eu" for a domain in the EU region. Defaults to "us". */
  region?: "us" | "eu";
}

/** Sends alerts as email through Mailgun. */
export function mailgun(options: MailgunOptions): AlertChannel {
  // A pasted credential often carries a stray space or newline, which a header would refuse or send.
  const apiKey = trimmed(options.apiKey);
  if (!apiKey) throw new Error("mailgun() needs an apiKey");
  if (!options.domain) throw new Error("mailgun() needs a domain");
  const to = recipients("mailgun", options);
  const host = options.region === "eu" ? "https://api.eu.mailgun.net" : "https://api.mailgun.net";
  const url = `${host}/v3/${encodeURIComponent(options.domain)}/messages`;
  return {
    name: "mailgun",
    async send(alert) {
      const email = composeEmail(alert, options, to);
      const form = new URLSearchParams();
      form.append("from", email.from);
      for (const address of email.to) form.append("to", address);
      form.append("subject", email.subject);
      form.append("text", email.text);
      form.append("html", email.html);
      form.append("o:tag", "cronwatch");
      await post("Mailgun", url, {
        headers: { "content-type": "application/x-www-form-urlencoded", authorization: basicAuth("api", apiKey) },
        body: form.toString(),
      }, [apiKey]);
    },
  };
}
