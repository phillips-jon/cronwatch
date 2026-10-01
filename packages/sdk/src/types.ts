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
   * did nothing. A RegExp runs on the runtime's own engine with no time limit,
   * as a function does, so avoid unbounded repeats that can match the same
   * text (`/\n*\n*x/`, `/(a+)+b/`): over a long output that does not match
   * they backtrack for seconds.
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
  /**
   * What started the run: "run", "start", "handler", an integration's name
   * ("pg_cron" for the pg_cron source) or a value you pass.
   */
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
  /** When an alert last reached at least one channel. */
  lastAlertAt: number | null;
  /**
   * Conditions that alerted and have since closed, waiting for the recovered
   * message that the next successful run sends. Absent in state written
   * before this field existed.
   */
  pendingRecovery?: Condition[];
  /** Alerts that no channel accepted. Each check retries them once. */
  undelivered?: Alert[];
  /**
   * The outbox: alerts written with the state that opened their condition,
   * while the process that wrote them sends them. Each leaves once that
   * process records how the send went; one still here after `until` (the
   * process stopped part way) goes to `undelivered` at the next check.
   * Absent when empty, and in state written before this field existed.
   */
  sending?: SendingAlert[];
  /**
   * Goes up by one on every write, so a store can refuse a write made from a
   * stale read (see Store.compareAndSetState). Absent counts as 0.
   */
  version?: number;
}

export type AlertType = Condition | "recovered";

export interface BudgetBreach {
  metric: string;
  value: number;
  limit: number;
  basis: string;
}

/** What each alert type carries in `details`. */
export interface AlertDetails {
  missed: { dueAt: number; deadline: number; graceMs: number; lastRunAt: number | null };
  failed: { consecutiveFailures: number; threshold: number };
  stuck: { consecutiveFailures: number; threshold: number };
  slow: { durationMs: number; thresholdMs: number; basis: string };
  over_budget: { breaches: BudgetBreach[] };
  /**
   * `after` names the conditions that closed. A recovery with `reason`
   * "unscheduled" closes missed alone because the job no longer has a
   * schedule; `since` is when missed opened. Without `reason`, a successful
   * run closed everything that was open.
   */
  recovered: { after: Condition[]; reason?: "unscheduled"; since?: number };
}

/** An alert before it has a title and message. See composeAlert(). */
export type AlertDraft = {
  [K in AlertType]: { type: K; run: Run | null; details: AlertDetails[K] };
}[AlertType];

interface AlertBase {
  job: string;
  definition: StoredJobDefinition;
  run: Run | null;
  /** One line, suitable as a notification title. */
  title: string;
  /** A few lines of plain text with the specifics. */
  message: string;
  /**
   * A short diagnosis from the triage function, when one is configured. Null
   * when triage was tried and gave nothing (it threw, timed out or answered
   * empty); it is not tried again for this alert.
   */
  triage?: string | null;
  at: number;
}

/** Narrow on `type` to read `details`: `if (alert.type === "slow") alert.details.durationMs`. */
export type Alert = {
  [K in AlertType]: AlertBase & { type: K; details: AlertDetails[K] };
}[AlertType];

/** An alert in JobState.sending: `until` (epoch milliseconds) is when its sender's lease runs out. */
export interface SendingAlert {
  until: number;
  alert: Alert;
}

/** What the client hands a channel with each alert. */
export interface ChannelContext {
  /**
   * Report a problem that did not stop the alert going out, such as one of
   * several recipients refusing it. Goes to the client's onError.
   */
  onError(error: unknown): void;
}

export interface AlertChannel {
  name: string;
  /** Resolves once the alert went out (to at least one recipient); throws when it went nowhere. */
  send(alert: Alert, context?: ChannelContext): Promise<void>;
}

/**
 * Where jobs, runs and state are kept. A store holds text without U+0000,
 * which Postgres refuses: it drops every NUL from a run's trigger, output,
 * error and metric names, and from every key and string of a definition and
 * a state, as it writes them. Job names and run ids never hold one.
 */
export interface Store {
  /** Called once before first use. Create tables here. */
  init?(): Promise<void>;
  upsertJob(definition: StoredJobDefinition, now: number): Promise<void>;
  getJob(name: string): Promise<StoredJob | null>;
  listJobs(): Promise<StoredJob[]>;
  deleteJob(name: string): Promise<void>;
  insertRun(run: Run): Promise<void>;
  updateRun(run: Run): Promise<void>;
  /**
   * Write a run's status, finishedAt, durationMs, error, output and metrics
   * only when its stored status is one of `fromStatuses`, in one step (SQL:
   * `UPDATE ... WHERE id = ? AND status IN (...)`). Returns whether it wrote.
   * This is what lets exactly one of several processes finishing the same run
   * evaluate it; the others see false and report the run as already finished.
   * A store without it falls back to getRun then updateRun, which is safe only
   * when one process at a time finishes a given run.
   */
  updateRunIf?(run: Run, fromStatuses: Run["status"][]): Promise<boolean>;
  getRun(id: string): Promise<Run | null>;
  /** Newest first. */
  listRuns(job: string, limit: number): Promise<Run[]>;
  lastRun(job: string): Promise<Run | null>;
  runningRuns(): Promise<Run[]>;
  getState(job: string): Promise<JobState | null>;
  /** Write a job's state unconditionally. Used only when compareAndSetState is missing. */
  setState(state: JobState): Promise<void>;
  /**
   * Write `state` only when the stored state's version (see JobState.version;
   * absent, or no row at all, counts as 0) equals `expectedVersion`. Returns
   * whether it wrote. This is what keeps two processes sharing a store from
   * overwriting each other's updates: the client reads, computes, and on a
   * refused write reads again. A store without it falls back to setState,
   * which is safe only when one process at a time writes a job's state.
   */
  compareAndSetState?(state: JobState, expectedVersion: number): Promise<boolean>;
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
  /** From the last twenty runs of any status; p50Ms and p95Ms are over the successful ones among them. */
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
  /** Aborts when the client stops waiting for a diagnosis. Pass it to any request you make. */
  signal: AbortSignal;
}

export type TriageFn = (context: TriageContext) => Promise<string | null>;
