/**
 * Postmark. API reference: https://postmarkapp.com/developer/api/email-api
 * POST https://api.postmarkapp.com/email with X-Postmark-Server-Token.
 */
import type { AlertChannel } from "../types.js";
import { composeEmail, recipients, type EmailOptions } from "./email.js";
import { post, trimmed } from "./shared.js";

export interface PostmarkOptions extends EmailOptions {
  /** A server API token, from the server's API Tokens tab. */
  serverToken: string;
  /** The message stream. Defaults to "outbound", the transactional stream. */
  messageStream?: string;
}

const ENDPOINT = "https://api.postmarkapp.com/email";

/** Sends alerts as email through Postmark. */
export function postmark(options: PostmarkOptions): AlertChannel {
  // A pasted credential often carries a stray space or newline, which a header would refuse or send.
  const serverToken = trimmed(options.serverToken);
  if (!serverToken) throw new Error("postmark() needs a serverToken");
  const to = recipients("postmark", options);
  return {
    name: "postmark",
    async send(alert) {
      const email = composeEmail(alert, options, to);
      await post("Postmark", ENDPOINT, {
        headers: { "content-type": "application/json", accept: "application/json", "x-postmark-server-token": serverToken },
        body: JSON.stringify({
          From: email.from,
          To: email.to.join(", "),
          Subject: email.subject,
          TextBody: email.text,
          HtmlBody: email.html,
          MessageStream: options.messageStream ?? "outbound",
          Tag: "cronwatch",
        }),
      }, [serverToken]);
    },
  };
}
