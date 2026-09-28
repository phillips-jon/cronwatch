/**
 * Helpers shared by the provider channels. Only fetch and Web Crypto, so the
 * channels run on Node, Cloudflare Workers, Deno and Bun alike. Not an entry
 * point: each channel bundles its own copy.
 */
import type { Alert } from "../types.js";

export const TIMEOUT_MS = 10_000;

/** Severity for trackers that have levels. Recovered is informational. */
export type Severity = "error" | "warning" | "info";

export function severity(type: Alert["type"]): Severity {
  if (type === "recovered") return "info";
  if (type === "slow" || type === "over_budget") return "warning";
  return "error";
}

/** The scheme, host and port only. A URL's path or query can hold a credential. */
export function origin(url: string): string {
  try {
    return new URL(url).origin;
  } catch {
    return "(invalid URL)";
  }
}

/**
 * The URL, once it is one fetch can post to. Refused without quoting it:
 * fetch's own error for a URL it cannot parse ("Failed to parse URL from ...")
 * quotes the whole URL, and a webhook URL's path is its credential.
 */
export function postable(url: string): string {
  let protocol: string;
  try {
    protocol = new URL(url).protocol;
  } catch {
    throw new Error("only http and https URLs can be posted to, not this URL");
  }
  if (protocol !== "http:" && protocol !== "https:") throw new Error(`only http and https URLs can be posted to, not ${protocol}`);
  return url;
}

/** How much of a provider's error body goes into the error message. */
export const ERROR_BODY_MAX = 200;

/**
 * POSTs and throws on a non-2xx answer. The error names the provider and the
 * URL's origin, plus the start of the response body with every secret the
 * channel holds cut out, in case a provider echoes one back. Secrets are cut
 * from a prefix long enough to hold one that starts inside the first
 * ERROR_BODY_MAX characters, and only then is it cut to that length, so no
 * part of a secret survives at the edge. A redirect is refused rather than
 * followed: the credential headers would go with it to wherever it points.
 */
export async function post(provider: string, url: string, init: { headers: Record<string, string>; body: string }, secrets: (string | undefined)[] = []): Promise<Response> {
  const response = await fetch(postable(url), { method: "POST", headers: init.headers, body: init.body, redirect: "error", signal: AbortSignal.timeout(TIMEOUT_MS) });
  if (!response.ok) {
    let text = "";
    try {
      text = await response.text();
    } catch {
      // The status is enough.
    }
    throw new Error(`${provider} ${origin(url)} answered ${response.status}${text ? `: ${errorBody(text, secrets)}` : ""}`);
  }
  return response;
}

/** The start of an error body, secrets cut out first, then cut to ERROR_BODY_MAX on a code point. */
export function errorBody(text: string, secrets: (string | undefined)[] = []): string {
  const kept = secrets.filter((s): s is string => typeof s === "string" && s.length >= 4);
  const longest = kept.reduce((n, s) => Math.max(n, s.length), 0);
  let head = cut(text, ERROR_BODY_MAX + longest);
  for (const secret of kept) head = head.split(secret).join("[redacted]");
  return cut(head, ERROR_BODY_MAX);
}

/** A credential with the spaces and newlines a paste leaves around it taken off. Anything not a string is empty. */
export function trimmed(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

/** Base64 of UTF-8, without Buffer. */
export function base64(text: string): string {
  let binary = "";
  for (const byte of new TextEncoder().encode(text)) binary += String.fromCharCode(byte);
  return btoa(binary);
}

export function basicAuth(user: string, password: string): string {
  return `Basic ${base64(`${user}:${password}`)}`;
}

export function hex(bytes: ArrayBuffer | Uint8Array): string {
  return Array.from(bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes), (b) => b.toString(16).padStart(2, "0")).join("");
}

export async function sha256Hex(text: string): Promise<string> {
  return hex(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)));
}

/**
 * A stable 32 hex character id for one alert: the same job, type and time
 * always give the same id, so a provider that deduplicates on it drops a
 * resend of an alert it already took.
 */
export async function alertId(alert: Alert): Promise<string> {
  return (await sha256Hex(`${alert.job}\n${alert.type}\n${alert.at}`)).slice(0, 32);
}

/** The same id laid out as a UUID, for APIs that ask for one. */
export function asUuid(id: string): string {
  return `${id.slice(0, 8)}-${id.slice(8, 12)}-${id.slice(12, 16)}-${id.slice(16, 20)}-${id.slice(20, 32)}`;
}

/** Cuts to at most `max` UTF-16 units without splitting a surrogate pair. */
export function cut(text: string, max: number): string {
  if (text.length <= max) return text;
  let end = max;
  const code = text.charCodeAt(end - 1);
  if (code >= 0xd800 && code <= 0xdbff) end -= 1;
  return text.slice(0, end);
}

/** The run fields worth attaching to a tracker event. */
export function runSummary(alert: Alert): Record<string, unknown> | null {
  const run = alert.run;
  if (!run) return null;
  return { id: run.id, status: run.status, startedAt: new Date(run.startedAt).toISOString(), durationMs: run.durationMs, trigger: run.trigger };
}

/** Title, message, triage and link as one plain text block, the way every channel reads. */
export function plainText(alert: Alert, link: string | undefined): string {
  return [alert.title, "", alert.message, ...(alert.triage ? ["", `Triage: ${alert.triage}`] : []), ...(link ? ["", `Open: ${link}`] : [])].join("\n");
}
