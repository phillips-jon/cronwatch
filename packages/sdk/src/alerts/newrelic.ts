/**
 * New Relic Event API. API reference: https://docs.newrelic.com/docs/data-apis/ingest-apis/event-api/introduction-event-api/
 * POST https://insights-collector.newrelic.com/v1/accounts/<id>/events
 * (insights-collector.eu01.nr-data.net for EU accounts) with Api-Key.
 * Each alert is one custom event of type CronWatchAlert, queryable with NRQL:
 * SELECT * FROM CronWatchAlert WHERE job = 'nightly'.
 */
import type { Alert, AlertChannel } from "../types.js";
import { cut, post, severity, trimmed } from "./shared.js";

export interface NewRelicOptions {
  /** The account id, the number in your New Relic URLs. */
  accountId: string | number;
  /** A license key (INGEST - LICENSE). */
  apiKey: string;
  /** "eu" for an account in the EU data center. Defaults to "us". */
  region?: "us" | "eu";
  /** Defaults to "CronWatchAlert". */
  eventType?: string;
  link?: (alert: Alert) => string;
}

/** Records alerts as New Relic custom events. */
export function newrelic(options: NewRelicOptions): AlertChannel {
  // A pasted credential often carries a stray space or newline, which a header would refuse or send.
  const apiKey = trimmed(options.apiKey);
  if (!apiKey) throw new Error("newrelic() needs an apiKey");
  const account = String(options.accountId ?? "");
  if (!/^\d+$/.test(account)) throw new Error("newrelic() needs a numeric accountId");
  const host = options.region === "eu" ? "https://insights-collector.eu01.nr-data.net" : "https://insights-collector.newrelic.com";
  const url = `${host}/v1/accounts/${account}/events`;
  const eventType = options.eventType ?? "CronWatchAlert";
  return {
    name: "newrelic",
    async send(alert) {
      const link = options.link?.(alert);
      const run = alert.run;
      // Flat attributes only, strings under 4096 characters.
      const event: Record<string, string | number> = {
        eventType,
        timestamp: alert.at,
        job: cut(alert.job, 4095),
        alertType: alert.type,
        severity: severity(alert.type),
        title: cut(alert.title, 4095),
        message: cut(alert.message, 4095),
      };
      if (alert.triage) event.triage = cut(alert.triage, 4095);
      if (link) event.link = cut(link, 4095);
      if (run) {
        event.runId = run.id;
        event.runStatus = run.status;
        if (run.durationMs !== null) event.durationMs = run.durationMs;
      }
      await post("New Relic", url, {
        headers: { "content-type": "application/json", "api-key": apiKey },
        body: JSON.stringify([event]),
      }, [apiKey]);
    },
  };
}
