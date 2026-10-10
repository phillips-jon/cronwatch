/**
 * Datadog Events API v1.
 * API reference: https://docs.datadoghq.com/api/latest/events/ (Post an event)
 * Field limits: https://datadoghq.dev/datadog-api-client-typescript/classes/v1.EventCreateRequest.html
 * POST https://api.<site>/api/v1/events with DD-API-KEY. Answers 202.
 */
import type { Alert, AlertChannel } from "../types.js";
import { cut, plainText, post, sha256Hex, trimmed } from "./shared.js";

export interface DatadogOptions {
  /** An API key (not an application key). */
  apiKey: string;
  /** Your Datadog site: "datadoghq.com" (the default), "datadoghq.eu", "us3.datadoghq.com", "us5.datadoghq.com", "ap1.datadoghq.com", "ddog-gov.com". */
  site?: string;
  /** Extra tags, "env:prod" say. Every event also has cronwatch, job:<name>, and alert:<type>. */
  tags?: string[];
  /** Associates the event with a host and its tags. */
  host?: string;
  link?: (alert: Alert) => string;
}

const ALERT_TYPE: Record<Alert["type"], "error" | "warning" | "success"> = {
  missed: "error",
  failed: "error",
  stuck: "error",
  slow: "warning",
  over_budget: "warning",
  under_floor: "warning",
  recovered: "success",
};

/** Posts alerts to the Datadog event stream, aggregated per job and alert type. */
export function datadog(options: DatadogOptions): AlertChannel {
  // A pasted credential often carries a stray space or newline, which a header would refuse or send.
  const apiKey = trimmed(options.apiKey);
  if (!apiKey) throw new Error("datadog() needs an apiKey");
  const site = (options.site ?? "datadoghq.com").replace(/^https?:\/\//, "").replace(/^(api|app)\./, "").replace(/\/+$/, "");
  if (!/^[a-z0-9.-]+$/i.test(site)) throw new Error("datadog() needs a site like datadoghq.com");
  const url = `https://api.${site}/api/v1/events`;
  return {
    name: "datadog",
    async send(alert) {
      const link = options.link?.(alert);
      const event = {
        title: cut(alert.title, 500),
        text: cut(plainText(alert, link), 4000),
        alert_type: ALERT_TYPE[alert.type],
        aggregation_key: await aggregationKey(alert),
        date_happened: Math.floor(alert.at / 1000),
        priority: "normal",
        tags: ["cronwatch", `job:${alert.job}`, `alert:${alert.type}`, ...(options.tags ?? [])],
        ...(options.host ? { host: options.host } : {}),
      };
      await post("Datadog", url, {
        headers: { "content-type": "application/json", accept: "application/json", "dd-api-key": apiKey },
        body: JSON.stringify(event),
      }, [apiKey]);
    },
  };
}

/** "cronwatch:<job>:<type>", or a hash of it when that passes Datadog's 100 characters. */
async function aggregationKey(alert: Alert): Promise<string> {
  const key = `cronwatch:${alert.job}:${alert.type}`;
  return key.length <= 100 ? key : `cronwatch:${(await sha256Hex(key)).slice(0, 40)}`;
}
