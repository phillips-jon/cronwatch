import { parseDuration } from "./duration.js";
import {
  BASELINE_WINDOW,
  emptyState,
  isSilenced,
  isStuck,
  muteOpens,
  onCheck,
  onRunFinish,
  onRunStart,
  openConditions,
  timeoutMs,
} from "./evaluate.js";
import type { AlertDraft, Evaluation } from "./evaluate.js";
import { composeAlert } from "./format.js";
import { json } from "./http.js";
import { createRecorder } from "./job.js";
import type { JobContext } from "./job.js";
import { errorMessage } from "./output.js";
import { parseSchedule } from "./schedule.js";
import { checkExpectation, toStored } from "./serialize.js";
import { percentile } from "./stats.js";
import { createRoutes } from "./routes/index.js";
import type { Routes, RoutesOptions } from "./routes/index.js";
import { memory } from "./stores/memory.js";
import type {
  Alert,
  AlertChannel,
  CheckResult,
  Condition,
  Duration,
  JobDefinition,
  JobOptions,
  JobState,
  JobSummary,
  Run,
  Store,
  StoredJob,
  StoredJobDefinition,
  TriageFn,
} from "./types.js";

export type JobFn<T> = (job: JobContext) => Promise<T> | T;
export type HandlerFn<T> = (job: JobContext, request: Request) => Promise<T> | T;

export interface HandlerOptions {
  /**
   * Callers must send `Authorization: Bearer <secret>`. Defaults to the
   * client's cronSecret, which defaults to process.env.CRON_SECRET (what
   * Vercel sends its cron requests with). Pass null to allow anyone.
   */
  secret?: string | null;
}

export interface JobHandle {
  readonly name: string;
  readonly definition: JobDefinition;
  /** Run the function now, recording the run. Rethrows whatever the function throws. */
  run<T>(fn: JobFn<T>, options?: { trigger?: string }): Promise<T>;
  /** A fetch-style request handler (Next.js route, Hono, Bun, Deno) that runs the function and records the run. */
  handler<T>(fn: HandlerFn<T>, options?: HandlerOptions): (request: Request) => Promise<Response>;
}

export interface CronWatchOptions {
  /** Where jobs, runs and state live. Defaults to an in-memory store that forgets on restart. */
  store?: Store;
  /** Where alerts go. Defaults to the console. */
  alerts?: AlertChannel[];
  /** Adds a short diagnosis to failure alerts. See @cronwatch/sdk/anthropic. */
  triage?: TriageFn;
  /** Shared secret that handler() requests must carry. Defaults to process.env.CRON_SECRET. */
  cronSecret?: string | null;
  /** How long finished runs are kept. Default "30d". */
  retention?: Duration;
  /** Applied to every job unless the job sets its own. */
  defaults?: Pick<JobOptions, "grace" | "timeout" | "timezone" | "failuresBeforeAlert">;
  /** Called with anything that goes wrong outside a job: an alert channel failing, a triage timeout. */
  onError?: (error: unknown, where: string) => void;
  /** The clock. Tests use this. */
  now?: () => number;
}

export interface ExecuteResult<T> {
  run: Run;
  result: T | undefined;
  error: unknown;
  threw: boolean;
}

const NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,119}$/;
const TRIAGE_TIMEOUT_MS = 25_000;
const PRUNE_INTERVAL_MS = 60 * 60_000;

function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export class CronWatch {
  readonly store: Store;
  readonly alerts: AlertChannel[];
  readonly triage: TriageFn | undefined;
  readonly cronSecret: string | null;
  readonly retentionMs: number;
  readonly now: () => number;
  readonly onError: (error: unknown, where: string) => void;
  private readonly defaults: NonNullable<CronWatchOptions["defaults"]>;
  private readonly definitions = new Map<string, JobDefinition>();
  private readonly synced = new Set<string>();
  private ready: Promise<void> | null = null;
  private checking: Promise<CheckResult> | null = null;
  private lastPruneAt = 0;
  private timer: ReturnType<typeof setInterval> | null = null;
  private usingDefaultStore = false;

  constructor(options: CronWatchOptions = {}) {
    this.store = options.store ?? (this.usingDefaultStore = true, memory());
    this.alerts = options.alerts ?? [consoleChannel()];
    this.triage = options.triage;
    this.cronSecret = options.cronSecret === undefined ? (process.env.CRON_SECRET ?? null) : options.cronSecret;
    this.retentionMs = parseDuration(options.retention ?? "30d", "retention");
    this.defaults = options.defaults ?? {};
    this.now = options.now ?? (() => Date.now());
    this.onError = options.onError ?? ((error, where) => console.error(`[cronwatch] ${where}:`, error));
  }

  /** Declare a job. Call it once, at module level, and keep the handle. */
  job(name: string, options: JobOptions = {}): JobHandle {
    if (!NAME_RE.test(name)) {
      throw new Error(`job name "${name}" must be 1 to 120 characters of letters, digits, ".", "_", ":" or "-"`);
    }
    const definition: JobDefinition = { ...this.defaults, ...options, name };
    if (definition.schedule) parseSchedule(definition.schedule, definition.timezone);
    if (definition.grace !== undefined) parseDuration(definition.grace, "grace");
    if (definition.timeout !== undefined) parseDuration(definition.timeout, "timeout");
    if (definition.maxDuration !== undefined) parseDuration(definition.maxDuration, "maxDuration");
    this.definitions.set(name, definition);
    this.synced.delete(name);
    return this.handle(definition);
  }

  /** Run a job by name without keeping a handle. Defines it on first use. */
  run<T>(name: string, fn: JobFn<T>): Promise<T>;
  run<T>(name: string, options: JobOptions, fn: JobFn<T>): Promise<T>;
  run<T>(name: string, optionsOrFn: JobOptions | JobFn<T>, maybeFn?: JobFn<T>): Promise<T> {
    const fn = typeof optionsOrFn === "function" ? optionsOrFn : maybeFn!;
    const options = typeof optionsOrFn === "function" ? undefined : optionsOrFn;
    const handle = options || !this.definitions.has(name) ? this.job(name, options) : this.handle(this.definitions.get(name)!);
    return handle.run(fn);
  }

  /** The definitions declared in this process. */
  definedJobs(): JobDefinition[] {
    return [...this.definitions.values()];
  }

  private handle(definition: JobDefinition): JobHandle {
    const self = this;
    return {
      name: definition.name,
      definition,
      async run<T>(fn: JobFn<T>, options?: { trigger?: string }): Promise<T> {
        const outcome = await self.execute(definition, fn, options?.trigger ?? "run");
        if (outcome.threw) throw outcome.error;
        return outcome.result as T;
      },
      handler<T>(fn: HandlerFn<T>, options?: HandlerOptions) {
        const secret = options?.secret === undefined ? self.cronSecret : options.secret;
        return async (request: Request): Promise<Response> => {
          if (secret) {
            const header = request.headers.get("authorization") ?? "";
            if (!constantTimeEqual(header, `Bearer ${secret}`)) {
              return json({ ok: false, error: "Unauthorized" }, 401);
            }
          }
          const outcome = await self.execute(definition, (job) => fn(job, request), "handler");
          if (outcome.result instanceof Response) return outcome.result;
          const body = {
            ok: outcome.run.status === "ok",
            job: definition.name,
            run: outcome.run.id,
            status: outcome.run.status,
            durationMs: outcome.run.durationMs,
            ...(outcome.run.error ? { error: outcome.run.error.split("\n")[0] } : {}),
          };
          return json(body, outcome.run.status === "ok" ? 200 : 500);
        };
      },
    };
  }

  private async ensureReady(): Promise<void> {
    if (!this.ready) {
      this.ready = (async () => {
        if (this.store.init) await this.store.init();
        if (this.usingDefaultStore && process.env.NODE_ENV === "production") {
          console.warn("[cronwatch] using the in-memory store: runs and state are lost on restart. Pass a store from @cronwatch/sdk/sqlite or @cronwatch/sdk/postgres.");
        }
      })();
    }
    await this.ready;
  }

  private async sync(definition: JobDefinition): Promise<void> {
    await this.ensureReady();
    if (this.synced.has(definition.name)) return;
    await this.store.upsertJob(toStored(definition), this.now());
    this.synced.add(definition.name);
  }

  /** Runs a function as a recorded run. Never throws for the job's own error; see `threw`. */
  async execute<T>(definition: JobDefinition, fn: JobFn<T>, trigger: string): Promise<ExecuteResult<T>> {
    await this.sync(definition);
    const startedAt = this.now();
    const run: Run = {
      id: crypto.randomUUID(),
      job: definition.name,
      status: "running",
      startedAt,
      finishedAt: null,
      durationMs: null,
      error: null,
      output: null,
      metrics: {},
      trigger,
    };
    await this.store.insertRun(run);

    const before = (await this.store.getState(definition.name)) ?? emptyState(definition.name);
    const started = onRunStart(before);
    if (openConditions(started.state).length !== openConditions(before).length) {
      await this.store.setState(started.state);
    }

    const recorder = createRecorder(run);
    const timer = setTimeout(() => recorder.abort(), timeoutMs(definition));
    if (typeof timer === "object" && "unref" in timer) timer.unref();

    let result: T | undefined;
    let error: unknown;
    let threw = false;
    try {
      result = await fn(recorder.context);
    } catch (e) {
      error = e;
      threw = true;
    } finally {
      clearTimeout(timer);
    }

    const finishedAt = this.now();
    run.finishedAt = finishedAt;
    run.durationMs = Math.max(0, finishedAt - startedAt);
    run.metrics = recorder.metrics();
    run.output = recorder.output() ?? (typeof result === "string" ? result : null);

    if (threw) {
      run.status = "failed";
      run.error = errorMessage(error);
    } else if (result instanceof Response && result.status >= 400) {
      run.status = "failed";
      run.error = `HTTP ${result.status}${result.statusText ? ` ${result.statusText}` : ""}`;
    } else {
      const unmet = checkExpectation(definition.expect, run.output);
      if (unmet) {
        run.status = "failed";
        run.error = unmet;
      } else {
        run.status = "ok";
      }
    }
    await this.store.updateRun(run);

    try {
      const history = (await this.store.listRuns(definition.name, BASELINE_WINDOW + 5)).filter((r) => r.id !== run.id);
      const state = (await this.store.getState(definition.name)) ?? emptyState(definition.name);
      const evaluation = onRunFinish(definition, run, state, history, started.openBefore, finishedAt);
      await this.settle(state, evaluation, toStored(definition), finishedAt);
    } catch (e) {
      this.onError(e, `evaluating ${definition.name}`);
    }

    return { run, result, error, threw };
  }

  /**
   * Look for missed and stuck runs across every job, send alerts, and prune
   * old runs. Call it from an interval (start()), a cron hitting the mounted
   * routes, or by hand. Concurrent calls share one check.
   */
  check(): Promise<CheckResult> {
    if (!this.checking) {
      this.checking = this.runCheck().finally(() => {
        this.checking = null;
      });
    }
    return this.checking;
  }

  private async runCheck(): Promise<CheckResult> {
    await this.ensureReady();
    for (const definition of this.definitions.values()) await this.sync(definition);
    const now = this.now();
    const alerts: Alert[] = [];

    // Runs that never reported back.
    for (const run of await this.store.runningRuns()) {
      const stored = await this.store.getJob(run.job);
      const declared = this.definitions.get(run.job);
      const definition = declared ? toStored(declared) : stored?.definition;
      if (!definition || !isStuck(definition, run, now)) continue;
      run.status = "timeout";
      run.finishedAt = now;
      run.durationMs = now - run.startedAt;
      run.error = `Still running after ${Math.round(timeoutMs(definition) / 60_000)} minutes; marked as timed out`;
      await this.store.updateRun(run);
      const history = (await this.store.listRuns(run.job, BASELINE_WINDOW + 5)).filter((r) => r.id !== run.id);
      const state = (await this.store.getState(run.job)) ?? emptyState(run.job);
      const evaluation = onRunFinish(definition, run, state, history, [], now);
      alerts.push(...(await this.settle(state, evaluation, definition, now)));
    }

    const jobs: JobSummary[] = [];
    for (const stored of await this.store.listJobs()) {
      const definition = stored.definition;
      const lastRun = await this.store.lastRun(stored.name);
      const state = (await this.store.getState(stored.name)) ?? emptyState(stored.name);
      const evaluation = onCheck(definition, stored, lastRun, state, now);
      alerts.push(...(await this.settle(state, evaluation, definition, now)));
      jobs.push(await this.summarize(stored, lastRun, evaluation.state, evaluation.nextExpectedAt, now));
    }

    let pruned = 0;
    if (now - this.lastPruneAt > PRUNE_INTERVAL_MS) {
      this.lastPruneAt = now;
      try {
        pruned = await this.store.prune(now - this.retentionMs);
      } catch (e) {
        this.onError(e, "pruning");
      }
    }

    return { checkedAt: now, jobs, alerts, pruned };
  }

  /** Every job the store knows about, with its health. Does not send alerts. */
  async jobs(): Promise<JobSummary[]> {
    await this.ensureReady();
    for (const definition of this.definitions.values()) await this.sync(definition);
    const now = this.now();
    const out: JobSummary[] = [];
    for (const stored of await this.store.listJobs()) {
      const lastRun = await this.store.lastRun(stored.name);
      const state = (await this.store.getState(stored.name)) ?? emptyState(stored.name);
      const { nextExpectedAt } = onCheck(stored.definition, stored, lastRun, state, now);
      out.push(await this.summarize(stored, lastRun, state, nextExpectedAt, now));
    }
    return out;
  }

  async jobSummary(name: string): Promise<JobSummary | null> {
    await this.ensureReady();
    const definition = this.definitions.get(name);
    if (definition) await this.sync(definition);
    const stored = await this.store.getJob(name);
    if (!stored) return null;
    const now = this.now();
    const lastRun = await this.store.lastRun(name);
    const state = (await this.store.getState(name)) ?? emptyState(name);
    const { nextExpectedAt } = onCheck(stored.definition, stored, lastRun, state, now);
    return this.summarize(stored, lastRun, state, nextExpectedAt, now);
  }

  async runs(name: string, limit = 50): Promise<Run[]> {
    await this.ensureReady();
    return this.store.listRuns(name, Math.min(500, Math.max(1, limit)));
  }

  async getRun(id: string): Promise<Run | null> {
    await this.ensureReady();
    return this.store.getRun(id);
  }

  /** Stop alerts for a job for a while. State keeps updating underneath. */
  async silence(name: string, duration: Duration): Promise<JobState> {
    await this.ensureReady();
    const state = (await this.store.getState(name)) ?? emptyState(name);
    state.silencedUntil = this.now() + parseDuration(duration, "silence duration");
    await this.store.setState(state);
    return state;
  }

  async unsilence(name: string): Promise<JobState> {
    await this.ensureReady();
    const state = (await this.store.getState(name)) ?? emptyState(name);
    state.silencedUntil = null;
    await this.store.setState(state);
    return state;
  }

  /** Remove a job and its runs from the store. A job still declared in code comes back on its next run. */
  async forget(name: string): Promise<void> {
    await this.ensureReady();
    this.definitions.delete(name);
    this.synced.delete(name);
    await this.store.deleteJob(name);
  }

  /** The dashboard and JSON API as fetch-style handlers. See createRoutes(). */
  routes(options?: RoutesOptions): Routes {
    return createRoutes(this, options);
  }

  /** Check on an interval, for long-running servers. Default every minute. */
  start(every: Duration = "1m"): void {
    if (this.timer) return;
    const ms = Math.max(5_000, parseDuration(every, "check interval"));
    const tick = () => this.check().catch((e) => this.onError(e, "check"));
    this.timer = setInterval(tick, ms);
    if (typeof this.timer === "object" && "unref" in this.timer) this.timer.unref();
    setTimeout(tick, 1_000).unref?.();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }

  async close(): Promise<void> {
    this.stop();
    if (this.store.close) await this.store.close();
  }

  private async summarize(stored: StoredJob, lastRun: Run | null, state: JobState, nextExpectedAt: number | null, now: number): Promise<JobSummary> {
    const recent = await this.store.listRuns(stored.name, BASELINE_WINDOW);
    const finished = recent.filter((r) => r.status !== "running");
    const okDurations = recent.filter((r) => r.status === "ok" && r.durationMs !== null).map((r) => r.durationMs!);
    const open = openConditions(state);
    let health: JobSummary["health"];
    if (state.silencedUntil !== null && state.silencedUntil > now) health = "silenced";
    else if (open.includes("stuck") || (lastRun && isStuck(stored.definition, lastRun, now))) health = "stuck";
    else if (open.includes("failed") || lastRun?.status === "failed" || lastRun?.status === "timeout") health = "failing";
    else if (open.includes("missed")) health = "late";
    else if (!lastRun) health = "never_ran";
    else health = "healthy";
    return {
      name: stored.name,
      definition: stored.definition,
      health,
      open,
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

  /** Save an evaluation's state, honouring silence, and send its alerts. */
  private async settle(previous: JobState, evaluation: Evaluation, definition: StoredJobDefinition, now: number): Promise<Alert[]> {
    if (isSilenced(previous, now)) {
      evaluation.state = muteOpens(previous, evaluation.state);
      evaluation.alerts = [];
    }
    if (JSON.stringify(evaluation.state) !== JSON.stringify(previous)) await this.store.setState(evaluation.state);
    return this.dispatch(evaluation.alerts, definition, evaluation.state, now);
  }

  private async dispatch(drafts: AlertDraft[], definition: StoredJobDefinition, state: JobState, now: number): Promise<Alert[]> {
    if (drafts.length === 0) return [];
    const sent: Alert[] = [];
    for (const draft of drafts) {
      const alert = composeAlert(draft, definition, now);
      if (this.triage && alert.type !== "recovered") {
        try {
          const recentRuns = await this.store.listRuns(alert.job, 5);
          const diagnosis = await withTimeout(this.triage({ alert, recentRuns }), TRIAGE_TIMEOUT_MS);
          if (diagnosis) alert.triage = diagnosis;
        } catch (e) {
          this.onError(e, `triage for ${alert.job}`);
        }
      }
      for (const channel of this.alerts) {
        try {
          await channel.send(alert);
        } catch (e) {
          this.onError(e, `alert channel ${channel.name}`);
        }
      }
      sent.push(alert);
    }
    state.lastAlertAt = now;
    await this.store.setState(state);
    return sent;
  }
}

function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const t = setTimeout(() => reject(new Error(`timed out after ${ms}ms`)), ms);
    promise.then((v) => { clearTimeout(t); resolve(v); }, (e) => { clearTimeout(t); reject(e); });
  });
}

/** Writes alerts to the console. The default channel. */
export function consoleChannel(): AlertChannel {
  return {
    name: "console",
    async send(alert) {
      const line = `[cronwatch] ${alert.title}\n${alert.message}${alert.triage ? `\nTriage: ${alert.triage}` : ""}`;
      if (alert.type === "recovered") console.info(line);
      else console.error(line);
    },
  };
}

/** Wrap any function as an alert channel. */
export function custom(name: string, send: (alert: Alert) => Promise<void> | void): AlertChannel {
  return { name, send: async (alert) => { await send(alert); } };
}

export type { Condition };
