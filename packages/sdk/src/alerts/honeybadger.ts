/**
 * Honeybadger, as error notices (not Check-ins, a separate product).
 * API reference: https://docs.honeybadger.io/api/reporting-exceptions/
 * POST https://api.honeybadger.io/v1/notices with X-API-Key. Answers 201.
 */
import type { Alert, AlertChannel } from "../types.js";
import { cut, post, runSummary } from "./shared.js";

export interface HoneybadgerOptions {
  /** The project API key, from Project Settings. */
  apiKey: string;
  /** Defaults to "production". */
  environment?: string;
  /** Another API host, "https://eu-api.honeybadger.io" say. Defaults to https://api.honeybadger.io. */
  endpoint?: string;
  /** Also send recoveries. Defaults to false: Honeybadger has no levels, so a recovery would read as an error. */
  recovered?: boolean;
  link?: (alert: Alert) => string;
}

const CLASS: Record<Alert["type"], string> = {
  missed: "CronWatch::Missed",
  failed: "CronWatch::Failed",
  stuck: "CronWatch::Stuck",
  slow: "CronWatch::Slow",
  over_budget: "CronWatch::OverBudget",
  recovered: "CronWatch::Recovered",
};

/** Reports alerts to Honeybadger as notices, one error per job and alert type. */
export function honeybadger(options: HoneybadgerOptions): AlertChannel {
  if (!options.apiKey) throw new Error("honeybadger() needs an apiKey");
  const url = `${(options.endpoint ?? "https://api.honeybadger.io").replace(/\/+$/, "")}/v1/notices`;
  return {
    name: "honeybadger",
    async send(alert) {
      if (alert.type === "recovered" && !options.recovered) return;
      const link = options.link?.(alert);
      const notice = {
        notifier: { name: "cronwatch", url: "https://cronwatch.dev" },
        error: {
          class: CLASS[alert.type],
          message: cut(`${alert.title}\n${alert.message}`, 8000),
          // No code ran here; one frame naming the job keeps the notice well formed.
          backtrace: [{ number: "0", file: `cronwatch/${alert.job}`, method: alert.type }],
          fingerprint: `cronwatch:${alert.job}:${alert.type}`,
          tags: ["cronwatch", alert.type],
        },
        request: {
          component: "cronwatch",
          action: alert.job,
          ...(link ? { url: link } : {}),
          context: {
            job: alert.job,
            type: alert.type,
            ...(alert.triage ? { triage: alert.triage } : {}),
            details: alert.details,
            run: runSummary(alert),
          },
        },
        server: { environment_name: options.environment ?? "production" },
      };
      await post("Honeybadger", url, {
        headers: { "content-type": "application/json", accept: "application/json", "x-api-key": options.apiKey },
        body: JSON.stringify(notice),
      }, [options.apiKey]);
    },
  };
}
