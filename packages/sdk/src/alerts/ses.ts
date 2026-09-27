/**
 * Amazon SES, API v2 SendEmail. API reference: https://docs.aws.amazon.com/ses/latest/APIReference-V2/API_SendEmail.html
 * POST https://email.<region>.amazonaws.com/v2/email/outbound-emails, signed
 * with AWS Signature Version 4 (see sigv4.ts), so no AWS SDK is needed.
 */
import type { AlertChannel } from "../types.js";
import { composeEmail, recipients, type EmailOptions } from "./email.js";
import { post, trimmed } from "./shared.js";
import { signV4 } from "./sigv4.js";

export interface SesOptions extends EmailOptions {
  /** The SES region, "us-east-1" say. The from identity must be verified there. */
  region: string;
  accessKeyId: string;
  secretAccessKey: string;
  /** For temporary credentials, an assumed role say. */
  sessionToken?: string;
  /** A configuration set for event publishing, if you use one. */
  configurationSetName?: string;
  /** The clock used to sign requests, in epoch milliseconds. For tests. */
  now?: () => number;
}

/** Sends alerts as email through Amazon SES. */
export function ses(options: SesOptions): AlertChannel {
  if (!options.region) throw new Error("ses() needs a region");
  if (!/^[a-z0-9-]+$/.test(options.region)) throw new Error("ses() needs a region like us-east-1");
  // A pasted credential often carries a stray space or newline, which would spoil the signature.
  const credentials = { accessKeyId: trimmed(options.accessKeyId), secretAccessKey: trimmed(options.secretAccessKey), sessionToken: trimmed(options.sessionToken) || undefined };
  if (!credentials.accessKeyId || !credentials.secretAccessKey) throw new Error("ses() needs an accessKeyId and secretAccessKey");
  const to = recipients("ses", options);
  const url = `https://email.${options.region}.amazonaws.com/v2/email/outbound-emails`;
  const now = options.now ?? Date.now;
  return {
    name: "ses",
    async send(alert) {
      const email = composeEmail(alert, options, to);
      const body = JSON.stringify({
        FromEmailAddress: email.from,
        Destination: { ToAddresses: email.to },
        Content: {
          Simple: {
            Subject: { Data: email.subject, Charset: "UTF-8" },
            Body: { Text: { Data: email.text, Charset: "UTF-8" }, Html: { Data: email.html, Charset: "UTF-8" } },
          },
        },
        ...(options.configurationSetName ? { ConfigurationSetName: options.configurationSetName } : {}),
        EmailTags: [{ Name: "source", Value: "cronwatch" }],
      });
      const headers = await signV4(
        { method: "POST", url, headers: { "content-type": "application/json" }, body, region: options.region, service: "ses", now: now() },
        credentials,
      );
      await post("SES", url, { headers, body }, [credentials.secretAccessKey, credentials.sessionToken]);
    },
  };
}
