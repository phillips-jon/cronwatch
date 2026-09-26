import type { Alert, AlertChannel, Store } from "../src/types.js";

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

/** Wraps a store so the named methods reject while they are in `broken`. */
export function flaky(store: Store, broken: Set<string>): Store {
  return new Proxy(store, {
    get(target, prop, receiver) {
      const value = Reflect.get(target, prop, receiver);
      if (typeof value !== "function") return value;
      return (...args: unknown[]) => (broken.has(String(prop)) ? Promise.reject(new Error(`store down: ${String(prop)}`)) : value.apply(target, args));
    },
  });
}

/** Lets pending promise callbacks and I/O callbacks run. */
export async function settle(rounds = 20): Promise<void> {
  for (let i = 0; i < rounds; i++) await new Promise((r) => setImmediate(r));
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
