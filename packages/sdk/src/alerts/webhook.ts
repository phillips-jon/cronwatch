import type { AlertChannel } from "../types.js";
import { postable } from "./shared.js";

export interface WebhookOptions {
  url: string;
  /** Extra request headers, for an Authorization header say. Values are trimmed. */
  headers?: Record<string, string>;
  /**
   * When set, each request carries `X-CronWatch-Signature: sha256=<hex>`,
   * the HMAC-SHA256 of the raw body with this secret, so the receiver can
   * verify it.
   */
  secret?: string;
}

const TIMEOUT_MS = 10_000;

function origin(url: string): string {
  try {
    return new URL(url).origin;
  } catch {
    return "(invalid URL)";
  }
}

/**
 * POSTs the alert as JSON to any URL. The body is the Alert object:
 * { type, job, title, message, run, details, triage, at, definition }.
 * A redirect is an error: point the url at where the receiver really is.
 */
export function webhook(options: WebhookOptions): AlertChannel {
  if (!options.url) throw new Error("webhook() needs a url");
  return {
    name: "webhook",
    async send(alert) {
      const body = JSON.stringify(alert);
      const headers: Record<string, string> = { "content-type": "application/json", "user-agent": "cronwatch" };
      // A pasted Authorization value often carries a stray space or newline, which fetch would refuse.
      for (const [name, value] of Object.entries(options.headers ?? {})) headers[name] = typeof value === "string" ? value.trim() : value;
      if (options.secret) {
        headers["x-cronwatch-signature"] = `sha256=${await hmacSha256Hex(options.secret, body)}`;
      }
      // A redirect is refused, not followed: the headers (and the signature) would go with it.
      const response = await fetch(postable(options.url), { method: "POST", headers, body, redirect: "error", signal: AbortSignal.timeout(TIMEOUT_MS) });
      // Only the origin: a webhook URL's path or query often is the credential.
      if (!response.ok) throw new Error(`Webhook ${origin(options.url)} answered ${response.status}`);
    },
  };
}

/** HMAC-SHA256 as lowercase hex, with Web Crypto so it runs on Workers and Deno too. */
export async function hmacSha256Hex(secret: string, body: string): Promise<string> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signature = new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode(body)));
  return Array.from(signature, (b) => b.toString(16).padStart(2, "0")).join("");
}
