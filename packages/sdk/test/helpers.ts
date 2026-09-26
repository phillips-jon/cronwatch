import type { Alert, AlertChannel } from "../src/types.js";

export function capture(): AlertChannel & { alerts: Alert[]; types(): string[] } {
  const alerts: Alert[] = [];
  return {
    name: "capture",
    alerts,
    types: () => alerts.map((a) => a.type),
    async send(alert) {
      alerts.push(alert);
    },
  };
}

export const T0 = Date.UTC(2026, 0, 5, 9, 30, 0); // Monday 2026-01-05 09:30:00Z
export const MIN = 60_000;
export const HOUR = 3_600_000;

export function clock(start = T0) {
  let now = start;
  return {
    now: () => now,
    set: (t: number) => { now = t; },
    advance: (ms: number) => { now += ms; return now; },
  };
}
