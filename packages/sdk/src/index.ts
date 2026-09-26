import { CronWatch } from "./client.js";
import type { CronWatchOptions } from "./client.js";

/**
 * Create a CronWatch client. One per app, at module level:
 *
 *   export const cw = cronwatch({ store: sqlite({ path: "./data/cronwatch.db" }), alerts: [slack({ webhookUrl })] });
 *   export const nightly = cw.job("nightly-report", { schedule: "0 2 * * *", grace: "15m" });
 */
export function cronwatch(options: CronWatchOptions = {}): CronWatch {
  return new CronWatch(options);
}

export { CronWatch, consoleChannel, custom } from "./client.js";
export { json } from "./http.js";
export type { CronWatchOptions, HandlerFn, HandlerOptions, JobFn, JobHandle } from "./client.js";
export type { JobContext } from "./job.js";
export { memory } from "./stores/memory.js";
export { createRoutes } from "./routes/index.js";
export type { RoutesOptions, Routes } from "./routes/index.js";
export { parseDuration, formatDuration, formatRelative } from "./duration.js";
export { parseSchedule, previousFire, nextFire } from "./schedule.js";
export { composeAlert } from "./format.js";
export type {
  Alert,
  AlertChannel,
  AlertType,
  CheckResult,
  Condition,
  Duration,
  ExpectRule,
  JobDefinition,
  JobHealth,
  JobOptions,
  JobState,
  JobSummary,
  Run,
  RunStatus,
  Store,
  StoredJob,
  StoredJobDefinition,
  TriageContext,
  TriageFn,
} from "./types.js";
