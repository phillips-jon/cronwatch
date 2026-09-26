/**
 * Pure decisions about a job's health. Each function takes the current state
 * and returns the new state plus the alerts that should go out. Nothing here
 * touches a store or a network, which is what makes it testable.
 */
import { formatDuration } from "./duration.js";
import { parseDuration } from "./duration.js";
import { expectation, parseSchedule, runCovers } from "./schedule.js";
import { median, percentile } from "./stats.js";
import type { Condition, JobDefinition, JobState, Run, StoredJob, StoredJobDefinition } from "./types.js";

export interface AlertDraft {
  type: Condition | "recovered";
  run: Run | null;
  details: Record<string, unknown>;
}

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
export const BASELINE_WINDOW = 20;

export function emptyState(job: string): JobState {
  return { job, open: {}, consecutiveFailures: 0, silencedUntil: null, lastAlertAt: null };
}

function cloneState(state: JobState): JobState {
  return { ...state, open: { ...state.open } };
}

function openCondition(state: JobState, condition: Condition, now: number): boolean {
  if (state.open[condition] !== undefined) return false;
  state.open[condition] = now;
  return true;
}

function closeCondition(state: JobState, condition: Condition): boolean {
  if (state.open[condition] === undefined) return false;
  delete state.open[condition];
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

export interface BudgetBreach {
  metric: string;
  value: number;
  limit: number;
  basis: string;
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

export function formatNumber(n: number): string {
  if (Number.isInteger(n)) return n.toLocaleString("en-US");
  return n.toLocaleString("en-US", { maximumFractionDigits: 4 });
}

/**
 * Called when a run starts. Missed and stuck are about the absence of a run,
 * so a run starting closes them without an alert. Returns which conditions
 * were open beforehand, for the recovered message at the end.
 */
export function onRunStart(state: JobState): { state: JobState; openBefore: Condition[] } {
  const next = cloneState(state);
  const openBefore = openConditions(next);
  closeCondition(next, "missed");
  closeCondition(next, "stuck");
  return { state: next, openBefore };
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
  openBefore: Condition[],
  now: number,
): Evaluation {
  const next = cloneState(state);
  const alerts: AlertDraft[] = [];

  if (run.status === "ok") {
    next.consecutiveFailures = 0;
    closeCondition(next, "failed");
    closeCondition(next, "missed");
    closeCondition(next, "stuck");

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

    const wasOpen = new Set([...openBefore, ...openConditions(state)]);
    if (wasOpen.size > 0 && openConditions(next).length === 0) {
      alerts.push({ type: "recovered", run, details: { after: [...wasOpen] } });
    }
    return { state: next, alerts };
  }

  // failed or timeout
  next.consecutiveFailures += 1;
  closeCondition(next, "missed");
  const threshold = Math.max(1, def.failuresBeforeAlert ?? 1);
  const condition: Condition = run.status === "timeout" ? "stuck" : "failed";
  if (next.consecutiveFailures >= threshold) {
    if (openCondition(next, condition, now)) {
      alerts.push({ type: condition, run, details: { consecutiveFailures: next.consecutiveFailures, threshold } });
    }
  }
  return { state: next, alerts };
}

/**
 * Called by check(). Decides whether the schedule has been missed. `lastRun`
 * is the most recent run of any status.
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
  const exp = expectation(parsed, now, lastRun?.startedAt ?? null, stored.createdAt, grace);

  let nextExpectedAt: number | null = null;
  if (parsed.kind === "interval") {
    nextExpectedAt = (lastRun?.startedAt ?? stored.createdAt) + parsed.everyMs!;
  } else {
    const upcoming = parsed.cron!.nextRun(new Date(now));
    nextExpectedAt = upcoming ? upcoming.getTime() : null;
  }

  if (!exp) return { state: next, alerts, nextExpectedAt, dueAt: null };

  // For a cron, a run at or after the fire covers it. For an interval the due
  // time is computed from the last run itself, so only the deadline matters.
  const covered = parsed.kind === "cron" && lastRun !== null && runCovers(lastRun.startedAt, exp.dueAt);
  if (covered) {
    closeCondition(next, "missed");
  } else if (now > exp.deadline) {
    if (openCondition(next, "missed", now)) {
      alerts.push({
        type: "missed",
        run: lastRun,
        details: { dueAt: exp.dueAt, deadline: exp.deadline, graceMs: grace, lastRunAt: lastRun?.startedAt ?? null },
      });
    }
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
