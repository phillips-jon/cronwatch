/**
 * Bugsnag, Error Reporting API, payload version 5.
 * API reference: https://developer.smartbear.com/bugsnag/docs/reporting-events-and-sessions
 * (formerly https://bugsnagerrorreportingapi.docs.apiary.io/)
 * POST https://notify.bugsnag.com/ with Bugsnag-Api-Key.
 */
import type { Alert, AlertChannel } from "../types.js";
import { cut, post, runSummary, severity, trimmed } from "./shared.js";

export interface BugsnagOptions {
  /** The project's notifier API key. */
  apiKey: string;
  /** Defaults to "production". */
  releaseStage?: string;
  /** Another notify endpoint, for on-premise installs. Defaults to https://notify.bugsnag.com/. */
  endpoint?: string;
  /** Also send recoveries, as info events. Defaults to false, since each one is an event on an error. */
  recovered?: boolean;
  /** The clock for the Bugsnag-Sent-At header, in epoch milliseconds. For tests. */
  now?: () => number;
  link?: (alert: Alert) => string;
}

/** Reports alerts to Bugsnag, grouped per job and alert type. */
export function bugsnag(options: BugsnagOptions): AlertChannel {
  // A pasted credential often carries a stray space or newline, which a header would refuse or send.
  const apiKey = trimmed(options.apiKey);
  if (!apiKey) throw new Error("bugsnag() needs an apiKey");
  const url = options.endpoint ?? "https://notify.bugsnag.com/";
  const now = options.now ?? Date.now;
  return {
    name: "bugsnag",
    async send(alert) {
      if (alert.type === "recovered" && !options.recovered) return;
      const link = options.link?.(alert);
      const payload = {
        apiKey,
        payloadVersion: "5",
        // The notifier's own version, not the SDK's; Bugsnag asks for one.
        notifier: { name: "cronwatch", version: "1.0.0", url: "https://cronwatch.dev" },
        events: [
          {
            exceptions: [{ errorClass: `CronWatch ${alert.type}`, message: cut(`${alert.title}\n${alert.message}`, 8000), stacktrace: [], type: "nodejs" }],
            severity: severity(alert.type),
            unhandled: false,
            severityReason: { type: "handledException" },
            context: alert.job,
            groupingHash: `cronwatch:${alert.job}:${alert.type}`,
            metaData: {
              cronwatch: {
                job: alert.job,
                type: alert.type,
                ...(alert.triage ? { triage: alert.triage } : {}),
                ...(link ? { link } : {}),
                details: alert.details,
                run: runSummary(alert),
              },
            },
            app: { releaseStage: options.releaseStage ?? "production" },
            device: { time: new Date(alert.at).toISOString() },
          },
        ],
      };
      await post("Bugsnag", url, {
        headers: {
          "content-type": "application/json",
          "bugsnag-api-key": apiKey,
          "bugsnag-payload-version": "5",
          "bugsnag-sent-at": new Date(now()).toISOString(),
        },
        body: JSON.stringify(payload),
      }, [apiKey]);
    },
  };
}
