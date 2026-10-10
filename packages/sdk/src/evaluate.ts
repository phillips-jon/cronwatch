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
  Alert,
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

/** The longest duration written: the largest integer JavaScript holds exactly, which every port and store reads back unchanged. */
export const MAX_DURATION_MS = Number.MAX_SAFE_INTEGER;

/**
 * How long a run took, from `startedAt` to `finishedAt`: 0 when it started
 * later, and never more than MAX_DURATION_MS. A foreign row's start near a
 * 64-bit limit must not make a duration no store can write.
 */
export function runDuration(startedAt: number, finishedAt: number): number {
  const ms = finishedAt - startedAt;
  return ms > 0 ? Math.min(ms, MAX_DURATION_MS) : 0;
}

/**
 * When a silence of `ms` from `now` ends: a whole millisecond, never past
 * MAX_DURATION_MS (2^53 - 1), however long the silence asked for. Every port
 * sharing the store reads it back unchanged, where a larger number could
 * wrap to a time long past and send alerts during the silence.
 */
export function silenceEnd(now: number, ms: number): number {
  return Math.min(now + Math.floor(Math.min(ms, MAX_DURATION_MS)), MAX_DURATION_MS);
}

/**
 * The version a stored state counts as for compareAndSetState: its
 * `version` when that is a whole number from 0 to MAX_DURATION_MS (2^53 - 1),
 * else 0, as when it is absent. The SQL stores read it the same way, so a
 * foreign row's `1.5`, `"x"`, or `-1` is written over by the next update
 * instead of refusing every compare-and-set of its job for good.
 */
export function stateVersion(state: Pick<JobState, "version"> | null | undefined): number {
  const version: unknown = state?.version;
  return typeof version === "number" && Number.isSafeInteger(version) && version >= 0 ? version + 0 : 0;
}

/**
 * The failures in a row a stored state counts as: its `consecutiveFailures`
 * when that is a whole number, held at MAX_DURATION_MS (2^53 - 1), and 0 when
 * it is negative or not a whole number. A foreign row's count past 2^53, or at
 * a 64-bit limit, stays at the top instead of losing precision or wrapping
 * negative, and a `1.5`, `"3"`, or `-1` counts as none.
 */
export function failureCount(state: Pick<JobState, "consecutiveFailures"> | null | undefined): number {
  const count: unknown = state?.consecutiveFailures;
  if (typeof count !== "number" || !Number.isInteger(count) || count <= 0) return 0;
  return Math.min(count, MAX_DURATION_MS);
}

export function emptyState(job: string): JobState {
  return { job, open: {}, consecutiveFailures: 0, silencedUntil: null, lastAlertAt: null, pendingRecovery: [], undelivered: [] };
}

/** A JSON object: not null, not an array. */
export function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/**
 * A stored state with every field present, or a fresh one. State written by
 * an older version lacks the newer fields. `sending` and `underFloor` are the
 * exceptions: each is there only while it holds something.
 *
 * Read leniently, since a foreign, hand-edited, or damaged row must affect
 * only its own job, and the next write puts it right: a state that is not
 * an object reads as none; `open` keeps only its entries whose value is a
 * number (anything but an object reads as {}); `silencedUntil` and
 * `lastAlertAt` that are not numbers read as null; `pendingRecovery` keeps
 * only its strings, and `undelivered` only its entries that are objects (a
 * list of neither shape reads as []), and `underFloor` only its strings
 * (absent when none). Unknown fields are kept as written.
 */
export function normalizeState(state: JobState | null, job: string): JobState {
  if (!isObject(state)) return emptyState(job);
  const { sending, underFloor, ...rest } = state;
  const open = isObject(state.open)
    ? Object.fromEntries(Object.entries(state.open).filter(([, at]) => typeof at === "number"))
    : {};
  const number = (value: unknown) => (typeof value === "number" ? value : null);
  const list = (value: unknown) => (Array.isArray(value) ? value : []);
  return {
    ...emptyState(job),
    ...rest,
    open,
    consecutiveFailures: failureCount(state),
    silencedUntil: number(state.silencedUntil),
    lastAlertAt: number(state.lastAlertAt),
    pendingRecovery: list(state.pendingRecovery).filter((c): c is Condition => typeof c === "string"),
    undelivered: list(state.undelivered).filter((alert): alert is Alert => isObject(alert)),
    ...(Array.isArray(sending) && sending.length > 0 ? { sending: [...sending] } : {}),
    ...(Array.isArray(underFloor) && underFloor.some((m) => typeof m === "string") ? { underFloor: underFloor.filter((m): m is string => typeof m === "string") } : {}),
  };
}

// ---------------------------------------------------------------- delivery

/** Alerts kept per job for retry, and per job being sent; past it the oldest go. */
export const MAX_UNDELIVERED = 20;

/**
 * How long an alert in `sending` is left to the process sending it. Longer
 * than any send takes: at most three alerts go out together, each with 25
 * seconds of triage and 15 of channels.
 */
export const SEND_LEASE_MS = 5 * 60_000;

/** Identifies an alert across retries, and in `sending`. */
export function alertKey(alert: Pick<Alert, "type" | "at" | "run">): string {
  return `${alert.type}|${alert.at}|${alert.run?.id ?? ""}`;
}

/** Keeps the newest `max` of `list`, and says how many went. */
function newest<T>(list: T[], max: number): { kept: T[]; dropped: number } {
  return { kept: list.slice(-max), dropped: Math.max(0, list.length - max) };
}

/**
 * `alerts` added to the undelivered queue: one with the same key as a queued
 * alert replaces it where it stands, the rest go at the end, and only the
 * newest MAX_UNDELIVERED stay. `dropped` counts those let go.
 */
export function queueUndelivered(state: JobState, alerts: Alert[]): { state: JobState; dropped: number } {
  const next = cloneState(state);
  const byKey = new Map(alerts.map((alert) => [alertKey(alert), alert]));
  const queue = next.undelivered!.map((alert) => byKey.get(alertKey(alert)) ?? alert);
  const known = new Set(queue.map(alertKey));
  queue.push(...alerts.filter((alert) => !known.has(alertKey(alert))));
  const { kept, dropped } = newest(queue, MAX_UNDELIVERED);
  next.undelivered = kept;
  return { state: next, dropped };
}

/**
 * The outbox. Alerts just composed are written with the state that opens
 * their condition, before any is sent, so a process that stops part way does
 * not lose them: into `sending`, each with its lease ending at `until`, when
 * this process sends them, or (deliver: "check") straight into the
 * undelivered queue for a check elsewhere. `dropped` counts alerts let go
 * past MAX_UNDELIVERED.
 */
export function holdAlerts(state: JobState, alerts: Alert[], until: number, deferred: boolean): { state: JobState; dropped: number } {
  if (alerts.length === 0) return { state, dropped: 0 };
  if (deferred) return queueUndelivered(state, alerts);
  const next = cloneState(state);
  const { kept, dropped } = newest([...(next.sending ?? []), ...alerts.map((alert) => ({ until, alert }))], MAX_UNDELIVERED);
  next.sending = kept;
  return { state: next, dropped };
}

/**
 * Alerts in `sending` whose lease ran out by `now`: the process sending them
 * stopped before it recorded how the send went. They go to the undelivered
 * queue, where the retry sends them (with triage, which is never stored with
 * them here) or drops them as stale. An entry that is not an object with an
 * alert is dropped; one without a numeric `until` counts as run out.
 */
export function releaseSending(state: JobState, now: number): { state: JobState; dropped: number } {
  const sending = state.sending ?? [];
  const lapsed = sending.filter((entry) => !(typeof entry?.until === "number" && entry.until > now));
  if (lapsed.length === 0) return { state, dropped: 0 };
  const held = sending.filter((entry) => !lapsed.includes(entry));
  return queueUndelivered(
    { ...state, sending: held },
    lapsed.filter((entry) => typeof entry?.alert === "object" && entry.alert !== null).map((entry) => entry.alert),
  );
}

/**
 * How a send went. Delivered and stale (`dropped`) alerts leave the queue;
 * failed ones replace their queued copy, so a triage made on this attempt is
 * kept, or join the queue. Every one of them leaves `sending`. lastAlertAt
 * moves only on a delivery. `dropped` in the result counts alerts let go
 * past MAX_UNDELIVERED.
 */
export function recordSent(state: JobState, delivered: Alert[], failed: Alert[], stale: Alert[], now: number): { state: JobState; dropped: number } {
  const next = cloneState(state);
  const done = new Set([...delivered, ...stale].map(alertKey));
  next.undelivered = next.undelivered!.filter((alert) => !done.has(alertKey(alert)));
  const sent = new Set([...delivered, ...failed, ...stale].map(alertKey));
  const held = (next.sending ?? []).filter((entry) => !(typeof entry?.alert === "object" && entry.alert !== null && sent.has(alertKey(entry.alert))));
  if (held.length > 0) next.sending = held;
  else delete next.sending;
  if (delivered.length > 0) next.lastAlertAt = now;
  return queueUndelivered(next, failed);
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

/**
 * The metrics of a successful run that fell below their floor. A metric
 * with a floor breaches when it reports less than that floor. One without
 * breaches when it reports 0 or less and either it did so on the job's last
 * successful run too (`previous`, the metrics under their floor then), or
 * the earlier successful runs that reported it (at least five, the newest
 * twenty) all reported more than 0. So a job that keeps writing nothing stays
 * under its floor however long it goes on, and a metric that is always 0
 * never alerts.
 */
export function floorBreaches(def: Pick<JobDefinition, "floor">, run: Run, history: Run[], previous: readonly string[] = []): BudgetBreach[] {
  const breaches: BudgetBreach[] = [];
  for (const [metric, value] of Object.entries(run.metrics)) {
    const floor = def.floor?.[metric];
    if (floor !== undefined) {
      if (value < floor) breaches.push({ metric, value, limit: floor, basis: "floor" });
      continue;
    }
    if (value > 0) continue;
    if (previous.includes(metric)) {
      breaches.push({ metric, value, limit: 0, basis: "0 or less on the run before too" });
      continue;
    }
    const past = history
      .filter((r) => r.status === "ok" && typeof r.metrics[metric] === "number")
      .slice(0, BASELINE_WINDOW)
      .map((r) => r.metrics[metric]!);
    if (past.length < BASELINE_MIN_RUNS || !past.every((v) => v > 0)) continue;
    const lowest = Math.min(...past);
    breaches.push({ metric, value, limit: lowest, basis: `the last ${past.length} runs all reported more than 0, the lowest ${formatNumber(lowest)}` });
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
 * Called when a run finishes with status ok, failed, or timeout. `history` is
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

    const short = floorBreaches(def, run, history, next.underFloor);
    if (short.length > 0) {
      next.underFloor = short.map((b) => b.metric);
      if (openCondition(next, "under_floor", now)) {
        alerts.push({ type: "under_floor", run, details: { breaches: short } });
      }
    } else {
      delete next.underFloor;
      closeCondition(next, "under_floor");
    }

    const pending = next.pendingRecovery ?? [];
    if (pending.length > 0 && openConditions(next).length === 0) {
      alerts.push({ type: "recovered", run, details: { after: [...pending] } });
      next.pendingRecovery = [];
    }
    return { state: next, alerts };
  }

  // failed or timeout
  // Held at the top: a count at the limit neither loses precision nor wraps below a threshold.
  next.consecutiveFailures = Math.min(next.consecutiveFailures + 1, MAX_DURATION_MS);
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
 * has run out. `lastRun` is the most recent run of any status. A job with no
 * schedule is never missed, and one whose schedule was removed while missed
 * was open gets a recovered alert (reason "unscheduled") for missed alone.
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
  if (!def.schedule) {
    const since = next.open.missed;
    if (since !== undefined) {
      // The schedule went away while missed was open (the job was declared
      // again without one, or a source retired it), so nothing is due any
      // more. Missed closes now with a recovery of its own; other open
      // conditions keep their own rules. Missed is taken out of the pending
      // recovery too, so the next successful run does not name it again.
      delete next.open.missed;
      next.pendingRecovery = (next.pendingRecovery ?? []).filter((c) => c !== "missed");
      alerts.push({ type: "recovered", run: lastRun, details: { after: ["missed"], reason: "unscheduled", since } });
    }
    return { state: next, alerts, nextExpectedAt: null, dueAt: null };
  }

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
 * names is open again; while they all stay closed it is kept. From a
 * foreign or damaged row: an alert whose `at` is not a number, and a
 * recovery whose `details.after` is not a list of strings, are stale.
 */
export function staleAlert(alert: AlertDraft & { at: number }, state: JobState): boolean {
  if (alert.type === "recovered") {
    // One whose details say nothing of what it recovers from (a foreign or damaged row's) cannot be judged, and goes.
    const after: unknown = isObject(alert.details) ? (alert.details as { after?: unknown }).after : undefined;
    if (!Array.isArray(after)) return true;
    return after.some((condition) => typeof condition !== "string" || state.open[condition as Condition] !== undefined);
  }
  // One with no time (a foreign or damaged row's) cannot match an open condition.
  return typeof alert.at !== "number" || state.open[alert.type] !== alert.at;
}

/** How a job looks at a glance. Silence wins, then stuck, failing, and late. */
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
