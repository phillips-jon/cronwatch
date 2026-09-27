/**
 * What every email channel sends: one subject, a plain text body and a small
 * HTML body, so an alert reads the same whichever provider carries it. Not an
 * entry point; resend, postmark, sendgrid, mailgun and ses each bundle it.
 */
import type { Alert } from "../types.js";
import { plainText } from "./shared.js";

/** The options every email channel takes. */
export interface EmailOptions {
  /** The sender, "alerts@example.com" or "CronWatch <alerts@example.com>". The provider must allow it. */
  from: string;
  /** One address or several. */
  to: string | string[];
  /** Put in front of the title in the subject, "[prod]" say. */
  subjectPrefix?: string;
  /** Link back to the job in your dashboard: (alert) => `https://app.example.com/cronwatch/jobs/${alert.job}`. */
  link?: (alert: Alert) => string;
}

export interface Email {
  from: string;
  to: string[];
  subject: string;
  text: string;
  html: string;
}

/** Checks the shared options once, when the channel is made. */
export function recipients(name: string, options: EmailOptions): string[] {
  if (!options.from) throw new Error(`${name}() needs a from address`);
  const to = (Array.isArray(options.to) ? options.to : [options.to]).filter((a) => typeof a === "string" && a.trim() !== "");
  if (to.length === 0) throw new Error(`${name}() needs at least one to address`);
  return to.map((a) => a.trim());
}

export function composeEmail(alert: Alert, options: EmailOptions, to: string[]): Email {
  const link = safeLink(options.link?.(alert));
  // One line: a newline in a subject is a header injection or a rejected send.
  const subject = `${options.subjectPrefix ? `${options.subjectPrefix} ` : ""}${alert.title}`.replace(/[\r\n]+/g, " ").slice(0, 250);
  return { from: options.from, to, subject, text: plainText(alert, link), html: html(alert, link) };
}

/** Escapes text for HTML content and double quoted attributes. */
export function escapeHtml(text: string): string {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

/** Only http and https links are put in a mail; anything else is dropped. */
function safeLink(link: string | undefined): string | undefined {
  if (!link) return undefined;
  return /^https?:\/\//i.test(link) ? link : undefined;
}

function html(alert: Alert, link: string | undefined): string {
  const parts = [
    `<!doctype html>`,
    `<html><body style="margin:0;padding:16px;font-family:Georgia,serif;color:#1d1b16;background:#ffffff">`,
    `<p style="margin:0 0 12px;font-size:18px"><strong>${escapeHtml(alert.title)}</strong></p>`,
    `<pre style="margin:0 0 12px;padding:12px;background:#f6f3ec;white-space:pre-wrap;word-break:break-word;font:13px/1.45 Menlo,Consolas,monospace">${escapeHtml(alert.message)}</pre>`,
  ];
  if (alert.triage) parts.push(`<p style="margin:0 0 12px"><em>Triage:</em> ${escapeHtml(alert.triage)}</p>`);
  if (link) parts.push(`<p style="margin:0"><a href="${escapeHtml(link)}">Open ${escapeHtml(alert.job)}</a></p>`);
  parts.push(`</body></html>`);
  return parts.join("\n");
}

/** Splits "Name <a@b.c>" into its parts; a bare address has no name. */
export function parseAddress(address: string): { email: string; name?: string } {
  const match = /^\s*(.*?)\s*<([^<>]+)>\s*$/.exec(address);
  if (!match) return { email: address.trim() };
  const name = match[1]!.replace(/^"(.*)"$/, "$1");
  return name ? { email: match[2]!.trim(), name } : { email: match[2]!.trim() };
}
