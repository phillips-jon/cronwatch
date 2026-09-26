/**
 * Pure decisions about a job's health. Each function takes the current state
 * and returns the new state plus the alerts that should go out. Nothing here
 * touches a store or a network, which is what makes it testable.
 */
import { formatDuration } from "./duration.js";
import { parseDuration } from "./duration.js";
import { expectation, nextFire, parseSchedule } from "./schedule.js";
import { median, percentile } from "./stats.js";
import type {
  AlertDraft,
  BudgetBreach,
  Condition,
  JobDefinition,
  JobHealth,
  JobState,
  JobSummary,
  Run,
  StoredJob,
  StoredJobDefinition,
} from "./types.js";

export type { AlertDraft, BudgetBreach };

export interface Evaluation {
  state: JobState;
  alerts: AlertDraft[];
}

export const DEFAULT_GRACE_MS = 10 * 60_000;
export const DEFAULT_TIMEOUT_MS = 60 * 60_000;
/** Runs faster than this are never called slow, whatever the baseline says. */
export const SLOW_FLOOR_MS = 10_000;
/** How many earlier runs a baseline needs before it is trusted. */
export const BASELINE_MIN_RUNS = 5;
/** How many successful runs a baseline looks at, and how many runs a summary covers. */
export const BASELINE_WINDOW = 20;

export function emptyState(job: string): JobState {
  return { job, open: {}, consecutiveFailures: 0, silencedUntil: null, lastAlertAt: null, pendingRecovery: [], undelivered: [] };
}

/** A stored state with every field present, or a fresh one. State written by an older version lacks the newer fields. */
export function normalizeState(state: JobState | null, job: string): JobState {
  if (!state) return emptyState(job);
  return {
    ...emptyState(job),
    ...state,
    open: { ...state.open },
    pendingRecovery: [...(state.pendingRecovery ?? [])],
    undelivered: [...(state.undelivered ?? [])],
  };
}

function cloneState(state: JobState): JobState {
  return normalizeState(state, state.job);
}

function openCondition(state: JobState, condition: Condition, now: number): boolean {
  if (state.open[condition] !== undefined) return false;
  state.open[condition] = now;
  return true;
}

/**
 * Every open condition has alerted, so closing one owes a recovered message.
 * It is remembered until a successful run leaves nothing open and sends it.
 */
function closeCondition(state: JobState, condition: Condition): boolean {
  if (state.open[condition] === undefined) return false;
  delete state.open[condition];
  const pending = (state.pendingRecovery ??= []);
  if (!pending.includes(condition)) pending.push(condition);
  return true;
}

export function openConditions(state: JobState): Condition[] {
  return Object.keys(state.open) as Condition[];
}

export function graceMs(def: Pick<JobDefinition, "grace">): number {
  return def.grace === undefined ? DEFAULT_GRACE_MS : parseDuration(def.grace, "grace");
}

export function timeoutMs(def: Pick<JobDefinition, "timeout">): number {
  return def.timeout === undefined ? DEFAULT_TIMEOUT_MS : parseDuration(def.timeout, "timeout");
}

/** Slow threshold for a successful run, or null when there is nothing to compare against yet. */
export function slowThreshold(def: Pick<JobDefinition, "maxDuration">, history: Run[]): { thresholdMs: number; basis: string } | null {
  if (def.maxDuration !== undefined) {
    return { thresholdMs: parseDuration(def.maxDuration, "maxDuration"), basis: "maxDuration" };
  }
  const durations = history
    .filter((r) => r.status === "ok" && r.durationMs !== null)
    .slice(0, BASELINE_WINDOW)
    .map((r) => r.durationMs!);
  if (durations.length < BASELINE_MIN_RUNS) return null;
  const p95 = percentile(durations, 95)!;
  return { thresholdMs: Math.max(2 * p95, SLOW_FLOOR_MS), basis: `twice the p95 of the last ${durations.length} runs (${formatDuration(p95)})` };
}

export function budgetBreaches(def: Pick<JobDefinition, "budget">, run: Run, history: Run[]): BudgetBreach[] {
  const breaches: BudgetBreach[] = [];
  for (const [metric, value] of Object.entries(run.metrics)) {
    const ceiling = def.budget?.[metric];
    if (ceiling !== undefined) {
      if (value > ceiling) breaches.push({ metric, value, limit: ceiling, basis: "budget" });
      continue;
    }
    const past = history
      .filter((r) => r.status === "ok" && typeof r.metrics[metric] === "number")
      .slice(0, BASELINE_WINDOW)
      .map((r) => r.metrics[metric]!);
    if (past.length < BASELINE_MIN_RUNS) continue;
    const usual = median(past)!;
    if (usual > 0 && value > 3 * usual) {
      breaches.push({ metric, value, limit: 3 * usual, basis: `three times the usual ${formatNumber(usual)}` });
    }
  }
  return breaches;
}

/** Whether `history` (newest first) holds a full baseline window of successful runs. */
export function hasFullBaseline(history: Run[]): boolean {
  return history.filter((r) => r.status === "ok").length >= BASELINE_WINDOW;
}

export function formatNumber(n: number): string {
  if (Number.isInteger(n)) return n.toLocaleString("en-US");
  return n.toLocaleString("en-US", { maximumFractionDigits: 4 });
}

/**
 * Called when a run starts. Missed and stuck are about the absence of a run,
 * so a run starting closes them without an alert; the recovered message
 * waits for a successful finish.
 */
export function onRunStart(state: JobState): JobState {
  const next = cloneState(state);
  closeCondition(next, "missed");
  closeCondition(next, "stuck");
  return next;
}

/**
 * Called when a run finishes with status ok, failed or timeout. `history` is
 * the job's earlier runs, newest first, not including this one.
 */
export function onRunFinish(
  def: JobDefinition | StoredJobDefinition,
  run: Run,
  state: JobState,
  history: Run[],
  now: number,
): Evaluation {
  const next = cloneState(state);
  const alerts: AlertDraft[] = [];

  if (run.status === "ok") {
    next.consecutiveFailures = 0;
    closeCondition(next, "missed");
    closeCondition(next, "stuck");
    closeCondition(next, "failed");

    const slow = slowThreshold(def, history);
    if (slow && run.durationMs !== null && run.durationMs > slow.thresholdMs) {
      if (openCondition(next, "slow", now)) {
        alerts.push({ type: "slow", run, details: { durationMs: run.durationMs, thresholdMs: slow.thresholdMs, basis: slow.basis } });
      }
    } else {
      closeCondition(next, "slow");
    }

    const breaches = budgetBreaches(def, run, history);
    if (breaches.length > 0) {
      if (openCondition(next, "over_budget", now)) {
        alerts.push({ type: "over_budget", run, details: { breaches } });
      }
    } else {
      closeCondition(next, "over_budget");
    }

    const pending = next.pendingRecovery ?? [];
    if (pending.length > 0 && openConditions(next).length === 0) {
      alerts.push({ type: "recovered", run, details: { after: [...pending] } });
      next.pendingRecovery = [];
    }
    return { state: next, alerts };
  }

  // failed or timeout
  next.consecutiveFailures += 1;
  closeCondition(next, "missed");
  const threshold = Math.max(1, def.failuresBeforeAlert ?? 1);
  const condition = run.status === "timeout" ? "stuck" : "failed";
  if (next.consecutiveFailures >= threshold) {
    if (openCondition(next, condition, now)) {
      alerts.push({ type: condition, run, details: { consecutiveFailures: next.consecutiveFailures, threshold } });
    }
  }
  return { state: next, alerts };
}

/**
 * Called by check(). Decides whether the schedule has been missed: the run
 * the schedule wants next (see expectation()) has not started and its grace
 * has run out. `lastRun` is the most recent run of any status.
 */
export function onCheck(
  def: StoredJobDefinition,
  stored: StoredJob,
  lastRun: Run | null,
  state: JobState,
  now: number,
): Evaluation & { nextExpectedAt: number | null; dueAt: number | null } {
  const next = cloneState(state);
  const alerts: AlertDraft[] = [];
  if (!def.schedule) return { state: next, alerts, nextExpectedAt: null, dueAt: null };

  const parsed = parseSchedule(def.schedule, def.timezone);
  const grace = graceMs(def);
  const lastRunAt = lastRun?.startedAt ?? null;
  const exp = expectation(parsed, lastRunAt, stored.createdAt, grace);
  const nextExpectedAt = parsed.kind === "interval" ? nextFire(parsed, stored.createdAt, lastRunAt) : nextFire(parsed, now, null);
  if (!exp) return { state: next, alerts, nextExpectedAt, dueAt: null };

  // An interval's next run is due a period after the last one started. If that
  // run is still going, the job is busy, not late; stuck covers one that never ends.
  if (parsed.kind === "interval" && lastRun?.status === "running") {
    return { state: next, alerts, nextExpectedAt, dueAt: exp.dueAt };
  }

  if (now > exp.deadline) {
    if (openCondition(next, "missed", now)) {
      alerts.push({ type: "missed", run: lastRun, details: { dueAt: exp.dueAt, deadline: exp.deadline, graceMs: grace, lastRunAt } });
    }
  } else {
    // A run has started since it opened, or the grace was widened.
    closeCondition(next, "missed");
  }
  return { state: next, alerts, nextExpectedAt, dueAt: exp.dueAt };
}

/** Whether a running run has gone on longer than the job's timeout. */
export function isStuck(def: Pick<JobDefinition, "timeout">, run: Run, now: number): boolean {
  return run.status === "running" && now - run.startedAt > timeoutMs(def);
}

/**
 * While a job is silenced nothing new is recorded as an incident: conditions
 * may close (so a job that recovered during the silence shows as healthy) but
 * none may open, so the first problem after the silence ends alerts normally.
 */
export function muteOpens(previous: JobState, next: JobState): JobState {
  const muted = cloneState(next);
  for (const condition of openConditions(muted)) {
    if (previous.open[condition] === undefined) delete muted.open[condition];
  }
  return muted;
}

export function isSilenced(state: JobState, now: number): boolean {
  return state.silencedUntil !== null && state.silencedUntil > now;
}

/**
 * An evaluation as it is saved and sent: while the job was silenced when it
 * began, nothing opens and nothing is sent.
 */
export function applySilence(previous: JobState, evaluation: Evaluation, now: number): Evaluation {
  if (!isSilenced(previous, now)) return evaluation;
  return { state: muteOpens(previous, evaluation.state), alerts: [] };
}

/**
 * Whether an alert waiting to be retried no longer describes the job, so it
 * is dropped rather than sent late. An alert for a condition is stale once
 * that condition has closed, or has closed and opened again (it opened at a
 * time other than the alert's). A recovery is stale when any condition it
 * names is open again; while they all stay closed it is kept.
 */
export function staleAlert(alert: AlertDraft & { at: number }, state: JobState): boolean {
  if (alert.type === "recovered") return alert.details.after.some((condition) => state.open[condition] !== undefined);
  return state.open[alert.type] !== alert.at;
}

/** How a job looks at a glance. Silence wins, then stuck, failing and late. */
export function jobHealth(def: Pick<JobDefinition, "timeout">, lastRun: Run | null, state: JobState, now: number): JobHealth {
  const open = openConditions(state);
  if (isSilenced(state, now)) return "silenced";
  if (open.includes("stuck") || (lastRun && isStuck(def, lastRun, now))) return "stuck";
  if (open.includes("failed") || lastRun?.status === "failed" || lastRun?.status === "timeout") return "failing";
  if (open.includes("missed")) return "late";
  if (!lastRun) return "never_ran";
  return "healthy";
}

/**
 * A job's summary from its most recent runs (newest first; the first
 * BASELINE_WINDOW are used) and its state. Stats cover runs of any status;
 * the percentiles are over the successful ones among them.
 */
export function summarize(stored: StoredJob, recent: Run[], state: JobState, nextExpectedAt: number | null, now: number): JobSummary {
  return summary(stored, recent, state, nextExpectedAt, (lastRun) => jobHealth(stored.definition, lastRun, state, now));
}

/**
 * The summary of a job that could not be evaluated, say because its stored
 * schedule no longer parses. It reads nothing from the definition. The job
 * shows as failing (or silenced, while it is), since it needs a look, and
 * nothing is known about when it is next due.
 */
export function unevaluableSummary(stored: StoredJob, recent: Run[], state: JobState, now: number): JobSummary {
  return summary(stored, recent, state, null, () => (isSilenced(state, now) ? "silenced" : "failing"));
}

function summary(stored: StoredJob, recent: Run[], state: JobState, nextExpectedAt: number | null, health: (lastRun: Run | null) => JobHealth): JobSummary {
  const window = recent.slice(0, BASELINE_WINDOW);
  const lastRun = window[0] ?? null;
  const finished = window.filter((r) => r.status !== "running");
  const okDurations = window.filter((r) => r.status === "ok" && r.durationMs !== null).map((r) => r.durationMs!);
  return {
    name: stored.name,
    definition: stored.definition,
    health: health(lastRun),
    open: openConditions(state),
    lastRun,
    nextExpectedAt,
    consecutiveFailures: state.consecutiveFailures,
    silencedUntil: state.silencedUntil,
    stats: {
      runs: finished.length,
      okRate: finished.length === 0 ? 1 : finished.filter((r) => r.status === "ok").length / finished.length,
      p50Ms: percentile(okDurations, 50),
      p95Ms: percentile(okDurations, 95),
    },
  };
}
