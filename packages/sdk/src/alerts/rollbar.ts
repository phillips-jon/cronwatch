/**
 * Rollbar. API reference: https://docs.rollbar.com/reference/create-item
 * POST https://api.rollbar.com/api/1/item/ with X-Rollbar-Access-Token.
 */
import type { Alert, AlertChannel } from "../types.js";
import { alertId, asUuid, cut, post, runSummary, severity, trimmed } from "./shared.js";

export interface RollbarOptions {
  /** A project access token with the post_server_item scope. */
  accessToken: string;
  /** Defaults to "production". */
  environment?: string;
  /** Also send recoveries, as info items. Defaults to true. */
  recovered?: boolean;
  link?: (alert: Alert) => string;
}

const ENDPOINT = "https://api.rollbar.com/api/1/item/";

/** Reports alerts to Rollbar, one item per job and alert type. */
export function rollbar(options: RollbarOptions): AlertChannel {
  // A pasted credential often carries a stray space or newline, which a header would refuse or send.
  const accessToken = trimmed(options.accessToken);
  if (!accessToken) throw new Error("rollbar() needs an accessToken");
  return {
    name: "rollbar",
    async send(alert) {
      if (alert.type === "recovered" && options.recovered === false) return;
      const link = options.link?.(alert);
      const item = {
        data: {
          environment: cut(options.environment ?? "production", 255),
          level: severity(alert.type),
          timestamp: Math.floor(alert.at / 1000),
          title: cut(alert.title, 255),
          // Rollbar hashes a fingerprint longer than 40 characters itself.
          fingerprint: `cronwatch:${alert.job}:${alert.type}`,
          uuid: asUuid(await alertId(alert)),
          body: { message: { body: alert.message } },
          custom: {
            job: alert.job,
            type: alert.type,
            ...(alert.triage ? { triage: alert.triage } : {}),
            ...(link ? { link } : {}),
            details: alert.details,
            run: runSummary(alert),
          },
          notifier: { name: "cronwatch" },
        },
      };
      await post("Rollbar", ENDPOINT, {
        headers: { "content-type": "application/json", "x-rollbar-access-token": accessToken },
        body: JSON.stringify(item),
      }, [accessToken]);
    },
  };
}
