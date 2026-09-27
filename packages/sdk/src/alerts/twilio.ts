/**
 * Twilio SMS. API reference: https://www.twilio.com/docs/messaging/api/message-resource
 * POST https://api.twilio.com/2010-04-01/Accounts/<AccountSid>/Messages.json,
 * form encoded, with basic auth. One recipient per request.
 */
import type { Alert, AlertChannel } from "../types.js";
import { basicAuth, cut, post, trimmed } from "./shared.js";

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
  /** How many SMS segments a message may use, 1 to 10. Defaults to 3. */
  segments?: number;
  link?: (alert: Alert) => string;
}

/** The most segments a message may use, which keeps it inside Twilio's 1600 character Body limit. */
export const MAX_SEGMENTS = 10;
/** Twilio refuses a Body longer than this. */
export const MAX_BODY = 1600;

/**
 * Texts alerts through Twilio, to every number at once. The alert counts as
 * delivered when any number took it; each number that refused it is
 * reported to the client's onError. It fails only when every number did.
 */
export function twilio(options: TwilioOptions): AlertChannel {
  // A pasted credential often carries a stray space or newline, which the Authorization header would refuse or send.
  const accountSid = trimmed(options.accountSid);
  if (!accountSid) throw new Error("twilio() needs an accountSid");
  const apiKeySid = trimmed(options.apiKeySid);
  const user = apiKeySid || accountSid;
  const password = apiKeySid ? trimmed(options.apiKeySecret) : trimmed(options.authToken);
  if (!password) throw new Error("twilio() needs an authToken, or an apiKeySid and apiKeySecret");
  if (!options.from && !options.messagingServiceSid) throw new Error("twilio() needs a from number or a messagingServiceSid");
  const to = (Array.isArray(options.to) ? options.to : [options.to]).filter((n) => typeof n === "string" && n.trim() !== "").map((n) => n.trim());
  if (to.length === 0) throw new Error("twilio() needs at least one to number");
  const url = `https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(accountSid)}/Messages.json`;
  const authorization = basicAuth(user, password);
  const segments = segmentBudget(options.segments);
  return {
    name: "twilio",
    async send(alert, context) {
      if (alert.type === "recovered" && !options.recovered) return;
      const body = smsBody(alert, options.link?.(alert), segments);
      const results = await Promise.allSettled(to.map((number) => {
        const form = new URLSearchParams();
        form.append("To", number);
        if (options.messagingServiceSid) form.append("MessagingServiceSid", options.messagingServiceSid);
        else form.append("From", options.from!);
        form.append("Body", body);
        return post("Twilio", url, { headers: { "content-type": "application/x-www-form-urlencoded", authorization }, body: form.toString() }, [password]);
      }));
      const failed = results.flatMap((r, i) => (r.status === "rejected" ? [{ number: to[i]!, error: r.reason as Error }] : []));
      if (failed.length === 0) return;
      if (failed.length === to.length) {
        const message = failed[0]!.error.message;
        throw new Error(to.length > 1 ? `${message} (${failed.length} of ${to.length} numbers failed)` : message);
      }
      // Delivered to someone: counted as sent, so a retry never texts the numbers that took it again.
      for (const { number, error } of failed) {
        const report = new Error(`${error.message} (to ${maskNumber(number)}; ${to.length - failed.length} of ${to.length} numbers took the alert)`);
        if (context) context.onError(report);
        else console.error("[cronwatch] alert channel twilio:", report);
      }
    },
  };
}

/** A number with all but its last four digits hidden, for an error message. */
function maskNumber(number: string): string {
  return number.length <= 4 ? number : `${"*".repeat(Math.min(number.length - 4, 8))}${number.slice(-4)}`;
}

// The GSM 03.38 alphabet: a message in it takes 153 characters a segment
// (when split), anything else is UCS-2 at 67. The extension table costs two.
const GSM = "@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !\"#¤%&'()*+,-./0123456789:;<=>?¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà";
const GSM_EXTENDED = "^{}\\[~]|€\f";

/**
 * The segments `text` takes. A character is never split across two: an
 * extension character (two septets) or a surrogate pair (two UCS-2 units)
 * that would straddle a boundary starts the next segment, as phones pack them.
 */
export function smsSegments(text: string): number {
  const units: number[] = [];
  let gsm = true;
  for (const ch of text) {
    if (GSM.includes(ch)) units.push(1);
    else if (GSM_EXTENDED.includes(ch)) units.push(2);
    else {
      gsm = false;
      break;
    }
  }
  const [single, per, sizes] = gsm ? [160, 153, units] : [70, 67, Array.from(text, (ch) => ch.length)];
  const total = sizes.reduce((n, u) => n + u, 0);
  if (total <= single) return 1;
  let count = 1;
  let used = 0;
  for (const u of sizes) {
    if (used + u > per) {
      count += 1;
      used = 0;
    }
    used += u;
  }
  return count;
}

/** Fits `text` within `segments` SMS segments and Twilio's Body limit. */
function fits(text: string, segments: number): boolean {
  return text.length <= MAX_BODY && smsSegments(text) <= segments;
}

/**
 * The title, then as many lines of the message (and the triage) as fit, then
 * the link. The link is kept whole; the text before it is cut to make room.
 * `segments` is clamped to 1 to 10.
 */
export function smsBody(alert: Alert, link: string | undefined, segments = 3): string {
  const budget = segmentBudget(segments);
  const tail = link ? `\n${link}` : "";
  const lines = [alert.title, ...alert.message.split("\n").filter((l) => l.trim() !== ""), ...(alert.triage ? [`Triage: ${alert.triage}`] : [])];
  let text = "";
  for (const line of lines) {
    const next = text ? `${text}\n${line}` : line;
    if (fits(next + tail, budget)) {
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
      if (fits(candidate + tail, budget)) lo = mid;
      else hi = mid - 1;
    }
    if (lo > 0) text = (text ? `${text}\n` : "") + chars.slice(0, lo).join("") + "...";
    break;
  }
  // Only a link too long for any budget gets here too long; Twilio would refuse it whole.
  return cut(text + tail, MAX_BODY);
}

/** A segment count clamped to 1 to MAX_SEGMENTS; 3 for anything not a number. */
function segmentBudget(segments: number | undefined): number {
  const n = typeof segments === "number" && Number.isFinite(segments) ? Math.floor(segments) : 3;
  return Math.min(MAX_SEGMENTS, Math.max(1, n));
}
