/**
 * Sentry, through the envelope endpoint.
 * Envelopes: https://develop.sentry.dev/sdk/data-model/envelopes/
 * Event payload: https://develop.sentry.dev/sdk/data-model/event-payloads/
 * DSN and X-Sentry-Auth: https://develop.sentry.dev/sdk/foundations/transport/authentication/
 */
import type { Alert, AlertChannel } from "../types.js";
import { alertId, cut, post, runSummary, severity, trimmed } from "./shared.js";

export interface SentryOptions {
  /** The project's DSN, "https://<key>@o0.ingest.sentry.io/<project>". */
  dsn: string;
  /** Defaults to "production". */
  environment?: string;
  release?: string;
  /** Also send recoveries, as info events. Defaults to true. */
  recovered?: boolean;
  link?: (alert: Alert) => string;
}

interface Dsn {
  endpoint: string;
  publicKey: string;
}

export function parseDsn(dsn: string): Dsn {
  let url: URL;
  try {
    url = new URL(dsn);
  } catch {
    throw new Error("sentry() needs a valid dsn");
  }
  const segments = url.pathname.split("/").filter(Boolean);
  const project = segments.pop();
  if (!url.username || !project || !/^\d+$/.test(project)) throw new Error("sentry() needs a dsn like https://<key>@<host>/<project>");
  const prefix = segments.length ? `/${segments.join("/")}` : "";
  return { endpoint: `${url.protocol}//${url.host}${prefix}/api/${project}/envelope/`, publicKey: decodeURIComponent(url.username) };
}

/** Sends alerts to Sentry as events, one issue per job and alert type. */
export function sentry(options: SentryOptions): AlertChannel {
  // A pasted credential often carries a stray space or newline, which a header would refuse or send.
  const dsn = trimmed(options.dsn);
  if (!dsn) throw new Error("sentry() needs a dsn");
  const { endpoint, publicKey } = parseDsn(dsn);
  return {
    name: "sentry",
    async send(alert) {
      if (alert.type === "recovered" && options.recovered === false) return;
      const eventId = await alertId(alert);
      const link = options.link?.(alert);
      const event = {
        event_id: eventId,
        timestamp: alert.at / 1000,
        platform: "other",
        level: severity(alert.type),
        logger: "cronwatch",
        transaction: alert.job,
        environment: options.environment ?? "production",
        ...(options.release ? { release: options.release } : {}),
        // The first line is the issue title.
        logentry: { formatted: cut(`${alert.title}\n\n${alert.message}`, 8192) },
        fingerprint: ["cronwatch", alert.job, alert.type],
        tags: { job: cut(alert.job, 199), type: alert.type },
        extra: {
          ...(alert.triage ? { triage: alert.triage } : {}),
          ...(link ? { link } : {}),
          details: alert.details,
          run: runSummary(alert),
        },
      };
      const payload = JSON.stringify(event);
      const envelope = [
        JSON.stringify({ event_id: eventId }),
        JSON.stringify({ type: "event", content_type: "application/json", length: new TextEncoder().encode(payload).length }),
        payload,
      ].join("\n") + "\n";
      await post("Sentry", endpoint, {
        headers: {
          "content-type": "application/x-sentry-envelope",
          "x-sentry-auth": `Sentry sentry_version=7, sentry_key=${publicKey}, sentry_client=cronwatch`,
        },
        body: envelope,
      }, [publicKey]);
    },
  };
}
