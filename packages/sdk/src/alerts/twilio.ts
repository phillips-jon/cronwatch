/**
 * Twilio SMS. API reference: https://www.twilio.com/docs/messaging/api/message-resource
 * POST https://api.twilio.com/2010-04-01/Accounts/<AccountSid>/Messages.json,
 * form encoded, with basic auth. One recipient per request.
 */
import type { Alert, AlertChannel } from "../types.js";
import { basicAuth, post } from "./shared.js";

export interface TwilioOptions {
  /** The account SID, "AC...". It is in the URL whichever credentials sign the request. */
  accountSid: string;
  /** The account's auth token. Or pass apiKeySid and apiKeySecret instead. */
  authToken?: string;
  /** An API key SID, "SK...", with apiKeySecret, in place of the auth token. */
  apiKeySid?: string;
  apiKeySecret?: string;
  /** A Twilio number in E.164 form, "+15005550006". Or pass messagingServiceSid. */
  from?: string;
  /** A messaging service SID, "MG...", in place of from. */
  messagingServiceSid?: string;
  /** One number in E.164 form, or several; each gets its own message. */
  to: string | string[];
  /** Also text when a job recovers. Defaults to false: a text is for what needs a person. */
  recovered?: boolean;
  /** How many SMS segments a message may use. Defaults to 3. */
  segments?: number;
  link?: (alert: Alert) => string;
}

/** Texts alerts through Twilio. */
export function twilio(options: TwilioOptions): AlertChannel {
  if (!options.accountSid) throw new Error("twilio() needs an accountSid");
  const user = options.apiKeySid ?? options.accountSid;
  const password = options.apiKeySid ? options.apiKeySecret : options.authToken;
  if (!password) throw new Error("twilio() needs an authToken, or an apiKeySid and apiKeySecret");
  if (!options.from && !options.messagingServiceSid) throw new Error("twilio() needs a from number or a messagingServiceSid");
  const to = (Array.isArray(options.to) ? options.to : [options.to]).filter((n) => typeof n === "string" && n.trim() !== "").map((n) => n.trim());
  if (to.length === 0) throw new Error("twilio() needs at least one to number");
  const url = `https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(options.accountSid)}/Messages.json`;
  const authorization = basicAuth(user, password);
  const segments = Math.max(1, Math.floor(options.segments ?? 3));
  return {
    name: "twilio",
    async send(alert) {
      if (alert.type === "recovered" && !options.recovered) return;
      const body = smsBody(alert, options.link?.(alert), segments);
      let first: unknown = null;
      let failed = 0;
      // Every number is tried; one bad number does not stop the others.
      for (const number of to) {
        const form = new URLSearchParams();
        form.append("To", number);
        if (options.messagingServiceSid) form.append("MessagingServiceSid", options.messagingServiceSid);
        else form.append("From", options.from!);
        form.append("Body", body);
        try {
          await post("Twilio", url, { headers: { "content-type": "application/x-www-form-urlencoded", authorization }, body: form.toString() }, [password]);
        } catch (error) {
          failed += 1;
          first ??= error;
        }
      }
      if (first) {
        const message = (first as Error).message;
        throw new Error(to.length > 1 ? `${message} (${failed} of ${to.length} numbers failed)` : message);
      }
    },
  };
}

// The GSM 03.38 alphabet: a message in it takes 153 characters a segment
// (when split), anything else is UCS-2 at 67. The extension table costs two.
const GSM = "@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !\"#¤%&'()*+,-./0123456789:;<=>?¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà";
const GSM_EXTENDED = "^{}\\[~]|€\f";

function gsmLength(text: string): number | null {
  let n = 0;
  for (const ch of text) {
    if (GSM.includes(ch)) n += 1;
    else if (GSM_EXTENDED.includes(ch)) n += 2;
    else return null;
  }
  return n;
}

/** Fits `text` within `segments` SMS segments, as GSM-7 when it can be and UCS-2 when not. */
function fits(text: string, segments: number): boolean {
  const gsm = gsmLength(text);
  if (gsm !== null) return gsm <= (segments === 1 ? 160 : 153 * segments);
  return text.length <= (segments === 1 ? 70 : 67 * segments);
}

/**
 * The title, then as many lines of the message (and the triage) as fit, then
 * the link. The link is kept whole; the text before it is cut to make room.
 */
export function smsBody(alert: Alert, link: string | undefined, segments = 3): string {
  const tail = link ? `\n${link}` : "";
  const lines = [alert.title, ...alert.message.split("\n").filter((l) => l.trim() !== ""), ...(alert.triage ? [`Triage: ${alert.triage}`] : [])];
  let text = "";
  for (const line of lines) {
    const next = text ? `${text}\n${line}` : line;
    if (fits(next + tail, segments)) {
      text = next;
      continue;
    }
    // Part of this line, cut on a code point and marked.
    const chars = Array.from(line);
    let lo = 0;
    let hi = chars.length;
    while (lo < hi) {
      const mid = Math.ceil((lo + hi) / 2);
      const candidate = (text ? `${text}\n` : "") + chars.slice(0, mid).join("") + "...";
      if (fits(candidate + tail, segments)) lo = mid;
      else hi = mid - 1;
    }
    if (lo > 0) text = (text ? `${text}\n` : "") + chars.slice(0, lo).join("") + "...";
    break;
  }
  return text + tail;
}
