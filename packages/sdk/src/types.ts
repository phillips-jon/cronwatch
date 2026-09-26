/**
 * Everything public about a job, a run and an alert. Kept in one file so the
 * store and alert adapters, which are built as separate entry points, share
 * one definition.
 */

/** "15m", "1h30m", "90s", "2d", or a number of milliseconds. */
export type Duration = string | number;

export type ExpectRule = string | RegExp | ((output: string) => boolean);

export interface JobOptions {
  /**
   * When the job is supposed to run. A five or six field cron expression
   * ("0 2 * * *"), a cron nickname ("@hourly"), or an interval ("every 5m").
   * Leave it out for a job that has no fixed cadence: failures, duration and
   * budgets are still watched, but nothing is ever reported as missed.
   */
  schedule?: string;
  /** IANA timezone the cron expression is read in. Defaults to the process timezone. */
  timezone?: string;
  /** How late a run may start before it counts as missed. Default "10m". */
  grace?: Duration;
  /** A run still going after this long is treated as stuck and marked timeout. Default "1h". */
  timeout?: Duration;
  /**
   * Alert when a successful run takes longer than this. Without it, a run is
   * slow when it takes more than twice the p95 of recent runs (and over 10s),
   * once there are at least five runs to compare against.
   */
  maxDuration?: Duration;
  /**
   * Ceilings for metrics reported with job.metric(). { cost: 2 } alerts when a
   * run reports cost above 2. Metrics without a ceiling alert when a run
   * reports more than three times the recent median, once there are at least
   * five runs to compare against.
   */
  budget?: Record<string, number>;
  /**
   * A successful run must produce output that satisfies this, or it counts as
   * failed. A string must appear in the output, a RegExp must match it, and a
   * function must return true for it. Catches the job that exits cleanly and
   * did nothing.
   */
  expect?: ExpectRule;
  /** Alert on the Nth consecutive failure rather than the first. Default 1. */
  failuresBeforeAlert?: number;
  description?: string;
  tags?: string[];
}

export interface JobDefinition extends JobOptions {
  name: string;
}

/**
 * The definition as it is written to a store. `expect` cannot be serialised
 * when it is a RegExp or a function, so it is described instead.
 */
export interface StoredJobDefinition extends Omit<JobDefinition, "expect"> {
  expect?: string;
}

export interface StoredJob {
  name: string;
  definition: StoredJobDefinition;
  createdAt: number;
  updatedAt: number;
}

export type RunStatus = "running" | "ok" | "failed" | "timeout";

export interface Run {
  id: string;
  job: string;
  status: RunStatus;
  /** Epoch milliseconds. */
  startedAt: number;
  finishedAt: number | null;
  durationMs: number | null;
  error: string | null;
  /** Lines written with job.log(), or the string the job returned. Capped at 16 KB. */
  output: string | null;
  metrics: Record<string, number>;
  /** What started the run: "handler", "run" or a value you pass. */
  trigger: string;
}

export type Condition = "missed" | "failed" | "stuck" | "slow" | "over_budget";

export const CONDITIONS: readonly Condition[] = ["missed", "failed", "stuck", "slow", "over_budget"];

export interface JobState {
  job: string;
  /** Conditions currently open, with the time each one opened. */
  open: Partial<Record<Condition, number>>;
  consecutiveFailures: number;
  silencedUntil: number | null;
  lastAlertAt: number | null;
}

export type AlertType = Condition | "recovered";

export interface Alert {
  type: AlertType;
  job: string;
  definition: StoredJobDefinition;
  run: Run | null;
  /** One line, suitable as a notification title. */
  title: string;
  /** A few lines of plain text with the specifics. */
  message: string;
  details: Record<string, unknown>;
  /** A short diagnosis from the triage function, when one is configured. */
  triage?: string;
  at: number;
}

export interface AlertChannel {
  name: string;
  send(alert: Alert): Promise<void>;
}

export interface Store {
  /** Called once before first use. Create tables here. */
  init?(): Promise<void>;
  upsertJob(definition: StoredJobDefinition, now: number): Promise<void>;
  getJob(name: string): Promise<StoredJob | null>;
  listJobs(): Promise<StoredJob[]>;
  deleteJob(name: string): Promise<void>;
  insertRun(run: Run): Promise<void>;
  updateRun(run: Run): Promise<void>;
  getRun(id: string): Promise<Run | null>;
  /** Newest first. */
  listRuns(job: string, limit: number): Promise<Run[]>;
  lastRun(job: string): Promise<Run | null>;
  runningRuns(): Promise<Run[]>;
  getState(job: string): Promise<JobState | null>;
  setState(state: JobState): Promise<void>;
  /** Delete finished runs that started before this time. Returns how many. */
  prune(before: number): Promise<number>;
  close?(): Promise<void>;
}

export type JobHealth = "healthy" | "late" | "failing" | "stuck" | "silenced" | "never_ran";

export interface JobSummary {
  name: string;
  definition: StoredJobDefinition;
  health: JobHealth;
  open: Condition[];
  lastRun: Run | null;
  /** When the schedule says the next run is due. Null without a schedule. */
  nextExpectedAt: number | null;
  consecutiveFailures: number;
  silencedUntil: number | null;
  /** From the last twenty successful runs. */
  stats: { runs: number; okRate: number; p50Ms: number | null; p95Ms: number | null };
}

export interface CheckResult {
  checkedAt: number;
  jobs: JobSummary[];
  alerts: Alert[];
  pruned: number;
}

export interface TriageContext {
  alert: Alert;
  recentRuns: Run[];
}

export type TriageFn = (context: TriageContext) => Promise<string | null>;
