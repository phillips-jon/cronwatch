import { formatDuration, parseDuration } from "./duration.js";
import {
  applySilence,
  BASELINE_WINDOW,
  emptyState,
  hasFullBaseline,
  isSilenced,
  isStuck,
  normalizeState,
  onCheck,
  onRunFinish,
  onRunStart,
  staleAlert,
  summarize,
  timeoutMs,
  unevaluableSummary,
} from "./evaluate.js";
import { composeAlert } from "./format.js";
import { constantTimeEqual, json } from "./http.js";
import { createRecorder } from "./job.js";
import type { JobContext } from "./job.js";
import { capOutput, errorMessage, redactSecrets, stripNul } from "./output.js";
import { parseSchedule } from "./schedule.js";
import { checkExpectation, toStored } from "./serialize.js";
import { createRoutes } from "./routes/index.js";
import type { Routes, RoutesOptions } from "./routes/index.js";
import { memory } from "./stores/memory.js";
import type {
  Alert,
  AlertChannel,
  AlertDraft,
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
   * Vercel sends its cron requests with). An empty string counts as unset.
   * With no secret at all the handler answers 503 unless NODE_ENV is
   * "development" or "test". Pass null to allow anyone.
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

/**
 * What a Source may use of the client: declare jobs, read the store, and
 * record runs it found elsewhere. A CronWatch is one.
 */
export interface SourceHost {
  /** Declare a job, as CronWatch.job(). Throws for an invalid name or option. */
  job(name: string, options?: JobOptions): unknown;
  /** See CronWatch.recordRun(). */
  recordRun(run: Run, options?: RecordRunOptions): Promise<Alert[]>;
  readonly store: Store;
  readonly now: () => number;
  readonly onError: (error: unknown, where: string) => void;
}

/**
 * Runs that happen somewhere CronWatch cannot wrap, such as inside the
 * database (see @cronwatch/sdk/pg-cron). check() calls sync() on each source
 * first, so what it records is evaluated in the same check.
 */
export interface Source {
  name: string;
  /** Declare the jobs and record their new runs. Returns the alerts recording them sent. */
  sync(host: SourceHost): Promise<Alert[] | void>;
}

export interface RecordRunOptions {
  /** False stores the run without evaluating it, for history imported on first sight. Default true. */
  evaluate?: boolean;
}

export interface CronWatchOptions {
  /** Where jobs, runs and state live. Defaults to an in-memory store that forgets on restart. */
  store?: Store;
  /**
   * Where runs this process does not wrap come from, such as pg_cron jobs.
   * Each is synced at the start of every check(); one that throws is
   * reported to onError and the check carries on.
   */
  sources?: Source[];
  /** Where alerts go. Defaults to the console. */
  alerts?: AlertChannel[];
  /** Adds a short diagnosis to every alert except recoveries. See @cronwatch/sdk/anthropic. */
  triage?: TriageFn;
  /**
   * Shared secret that handler() requests must carry. Defaults to
   * process.env.CRON_SECRET; an empty string counts as unset. Pass null to
   * let handlers run without one.
   */
  cronSecret?: string | null;
  /** How long finished runs are kept. Default "30d". */
  retention?: Duration;
  /** Applied to every job unless the job sets its own. */
  defaults?: Pick<JobOptions, "grace" | "timeout" | "timezone" | "failuresBeforeAlert">;
  /**
   * Applied to every run's output and error before it is stored, shown or
   * sent to an alert channel or triage. The default blanks values that look
   * like secrets (password=..., Authorization headers, URL credentials, bearer
   * tokens, JWTs, PEM private keys, webhook URLs, AWS, GitHub, Slack, Stripe,
   * Google and API key formats). Pass your own function, or false to keep
   * output exactly as logged. A function that throws or returns something
   * other than a string is reported to onError and the default is used.
   */
  redact?: ((text: string) => string) | false;
  /**
   * "now" (the default) sends alerts from this process. "check" sends nothing
   * from here: each alert is queued in the store and the next check, in a
   * process that delivers now, sends it (with triage). For a process that
   * records runs but cannot reach the network, such as a sandboxed backup job.
   * Its `alerts` and `triage` are not used.
   */
  deliver?: "now" | "check";
  /** Called with anything that goes wrong outside a job: the store failing, an alert channel failing, a triage timeout. */
  onError?: (error: unknown, where: string) => void;
  /** The clock. Tests use this. */
  now?: () => number;
}

interface ExecuteResult<T> {
  run: Run;
  result: T | undefined;
  error: unknown;
  threw: boolean;
}

const NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,119}$/;
const TRIAGE_TIMEOUT_MS = 25_000;
/** How long one channel may take to send one alert. */
const CHANNEL_TIMEOUT_MS = 15_000;
const PRUNE_INTERVAL_MS = 60 * 60_000;
/** Undelivered alerts kept per job for retry; the oldest go first. */
const MAX_UNDELIVERED = 20;
/**
 * Wall-clock time one check spends retrying undelivered alerts, across every
 * job. Once it is spent the rest wait for the next check.
 */
const RETRY_BUDGET_MS = 20_000;
/** Reads and writes of one job's state before an update gives up on a store that keeps changing under it. */
const STATE_ATTEMPTS = 10;
/** Runs read for a baseline, and the most read when failures crowd out the successes. */
const HISTORY_PAGE = BASELINE_WINDOW + 5;
const HISTORY_MAX = 200;

/** Throws a clear error for options that would otherwise quietly turn a check off. */
function validateDefinition(def: JobDefinition): void {
  const name = def.name;
  if (def.schedule !== undefined) {
    if (typeof def.schedule !== "string" || def.schedule.trim() === "") throw new Error(`job "${name}": schedule must be a non-empty string`);
    parseSchedule(def.schedule, def.timezone);
  }
  if (def.timezone !== undefined) {
    try {
      new Intl.DateTimeFormat("en-US", { timeZone: def.timezone });
    } catch {
      throw new Error(`job "${name}": timezone "${def.timezone}" is not an IANA timezone`);
    }
  }
  if (def.grace !== undefined) parseDuration(def.grace, "grace");
  if (def.timeout !== undefined && parseDuration(def.timeout, "timeout") <= 0) throw new Error(`job "${name}": timeout must be longer than zero`);
  if (def.maxDuration !== undefined && parseDuration(def.maxDuration, "maxDuration") <= 0) {
    throw new Error(`job "${name}": maxDuration must be longer than zero`);
  }
  if (def.failuresBeforeAlert !== undefined && !(Number.isInteger(def.failuresBeforeAlert) && def.failuresBeforeAlert >= 1)) {
    throw new Error(`job "${name}": failuresBeforeAlert must be a whole number, 1 or more (got ${String(def.failuresBeforeAlert)})`);
  }
  if (def.budget !== undefined) {
    if (typeof def.budget !== "object" || def.budget === null) throw new Error(`job "${name}": budget must be an object of { metric: ceiling }`);
    for (const [metric, ceiling] of Object.entries(def.budget)) {
      if (typeof ceiling !== "number" || !Number.isFinite(ceiling) || ceiling < 0) {
        throw new Error(`job "${name}": budget.${metric} must be a finite number, 0 or more (got ${String(ceiling)})`);
      }
    }
  }
  if (def.expect !== undefined && typeof def.expect !== "string" && !(def.expect instanceof RegExp) && typeof def.expect !== "function") {
    throw new Error(`job "${name}": expect must be a string, a RegExp or a function`);
  }
}

function sameState(a: JobState, b: JobState): boolean {
  return JSON.stringify(a) === JSON.stringify(b);
}

/** Identifies an alert across retries. */
function alertKey(alert: Alert): string {
  return `${alert.type}|${alert.at}|${alert.run?.id ?? ""}`;
}

export class CronWatch {
  readonly store: Store;
  readonly alerts: AlertChannel[];
  readonly triage: TriageFn | undefined;
  readonly sources: Source[];
  /** The secret handler() requests must carry, or null when none is set. */
  readonly cronSecret: string | null;
  readonly retentionMs: number;
  readonly now: () => number;
  readonly onError: (error: unknown, where: string) => void;
  /** cronSecret was passed as null: handlers may run without a secret. */
  private readonly secretOptOut: boolean;
  private readonly redact: (text: string) => string;
  /** "check": queue alerts for another process's check instead of sending them. See CronWatchOptions.deliver. */
  private readonly deferDelivery: boolean;
  private readonly defaults: NonNullable<CronWatchOptions["defaults"]>;
  private readonly definitions = new Map<string, JobDefinition>();
  private readonly synced = new Set<string>();
  /** The tail of each job's queue of state updates. See serial(). */
  private readonly queues = new Map<string, Promise<void>>();
  private ready: Promise<void> | null = null;
  private checking: Promise<CheckResult> | null = null;
  private lastPruneAt = 0;
  private timer: ReturnType<typeof setInterval> | null = null;
  private firstTick: ReturnType<typeof setTimeout> | null = null;
  private usingDefaultStore = false;
  private warnedNoSecret = false;
  private warnedDeferredStart = false;

  constructor(options: CronWatchOptions = {}) {
    this.store = options.store ?? (this.usingDefaultStore = true, memory());
    this.alerts = options.alerts ?? [consoleChannel()];
    this.triage = options.triage;
    this.sources = options.sources ?? [];
    const secret = options.cronSecret === undefined ? process.env.CRON_SECRET : options.cronSecret;
    this.cronSecret = secret ? secret : null;
    this.secretOptOut = options.cronSecret === null;
    this.retentionMs = parseDuration(options.retention ?? "30d", "retention");
    this.defaults = options.defaults ?? {};
    this.now = options.now ?? (() => Date.now());
    const redact = options.redact;
    this.redact = redact === false ? (text) => text
      : typeof redact === "function" ? (text) => {
          try {
            const out: unknown = redact(text);
            if (typeof out !== "string") throw new TypeError(`redact must return a string, not ${out === null ? "null" : typeof out}`);
            return out;
          } catch (e) {
            // A broken redact must not stop the run finishing, nor leak what it was given.
            this.report(e, "redact");
            return redactSecrets(text);
          }
        }
      : redactSecrets;
    if (options.deliver !== undefined && options.deliver !== "now" && options.deliver !== "check") {
      throw new Error(`deliver must be "now" or "check", not ${JSON.stringify(options.deliver)}`);
    }
    this.deferDelivery = options.deliver === "check";
    this.onError = options.onError ?? ((error, where) => console.error(`[cronwatch] ${where}:`, error));
  }

  /** Declare a job. Call it once, at module level, and keep the handle. */
  job(name: string, options: JobOptions = {}): JobHandle {
    if (!NAME_RE.test(name)) {
      throw new Error(`job name "${name}" must be 1 to 120 characters of letters, digits, ".", "_", ":" or "-"`);
    }
    const definition: JobDefinition = { ...this.defaults, ...options, name };
    validateDefinition(definition);
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
        const own = options?.secret;
        const secret = own === null ? null : own ? own : self.cronSecret;
        const optedOut = own === null || (!own && self.secretOptOut);
        return async (request: Request): Promise<Response> => {
          if (!secret && !optedOut && !isDevelopment()) {
            self.warnNoSecret();
            return json({ ok: false, error: "CRON_SECRET is not set, so this job will not run for an unauthenticated request. Set it, or pass secret: null to handler() to allow anyone." }, 503);
          }
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
            // Error text only goes to a caller who proved they hold the secret.
            ...(secret && outcome.run.error ? { error: outcome.run.error.split("\n")[0] } : {}),
          };
          return json(body, outcome.run.status === "ok" ? 200 : 500);
        };
      },
    };
  }

  private warnNoSecret(): void {
    if (this.warnedNoSecret) return;
    this.warnedNoSecret = true;
    this.onError(new Error("handler() refused a request because no CRON_SECRET is set; pass secret: null to allow unauthenticated requests"), "handler");
  }

  /** onError, for places that must carry on even when onError itself throws. */
  private report(error: unknown, where: string): void {
    try {
      this.onError(error, where);
    } catch {
      // Nothing more can be done with it.
    }
  }

  private async ensureReady(): Promise<void> {
    if (!this.ready) {
      this.ready = (async () => {
        if (this.store.init) await this.store.init();
        if (this.usingDefaultStore && process.env.NODE_ENV === "production") {
          console.warn("[cronwatch] using the in-memory store: runs and state are lost on restart. Pass a store from @cronwatch/sdk/sqlite or @cronwatch/sdk/postgres.");
        }
      })().catch((error: unknown) => {
        // Let the next call try again rather than failing forever.
        this.ready = null;
        throw error;
      });
    }
    await this.ready;
  }

  private async sync(definition: JobDefinition): Promise<void> {
    await this.ensureReady();
    if (this.synced.has(definition.name)) return;
    await this.store.upsertJob(toStored(definition), this.now());
    this.synced.add(definition.name);
  }

  /**
   * Runs `fn` after every earlier state update for the same job has settled,
   * so two runs (or a run and a check) in this process never read and write
   * the job's state over each other. Other processes are coordinated by
   * updateState() instead.
   */
  private serial<T>(job: string, fn: () => Promise<T>): Promise<T> {
    const result = (this.queues.get(job) ?? Promise.resolve()).then(fn);
    const tail = result.then(() => {}, () => {});
    this.queues.set(job, tail);
    void tail.then(() => {
      if (this.queues.get(job) === tail) this.queues.delete(job);
    });
    return result;
  }

  private async readState(job: string): Promise<JobState> {
    return normalizeState(await this.store.getState(job), job);
  }

  /**
   * Every read-modify-write of a job's state goes through here. In turn with
   * this process's other updates to the job (serial()), it reads the state,
   * asks `change` for the next one, and writes it with the version one
   * higher, only if the stored version is still the one read. When another
   * process wrote in between, the write is refused and it starts again from
   * a fresh read, up to STATE_ATTEMPTS times. So `change` may run more than
   * once and must only compute: whatever it returns from the attempt that
   * was written is the result. Nothing is written when the state is
   * unchanged. Returns the state as stored.
   */
  private updateState<T>(
    job: string,
    change: (current: JobState) => { state: JobState; result: T } | Promise<{ state: JobState; result: T }>,
  ): Promise<{ state: JobState; result: T }> {
    return this.serial(job, async () => {
      for (let attempt = 1; ; attempt++) {
        const current = await this.readState(job);
        const { state, result } = await change(current);
        if (sameState(state, current)) return { state: current, result };
        const version = current.version ?? 0;
        const next: JobState = { ...state, version: version + 1 };
        if (await this.writeState(next, version)) return { state: next, result };
        if (attempt >= STATE_ATTEMPTS) {
          throw new Error(`the state of ${job} changed under ${STATE_ATTEMPTS} attempts in a row to update it; gave up`);
        }
      }
    });
  }

  /** A conditional write, or for a store without compareAndSetState, a plain one that always succeeds. */
  private async writeState(state: JobState, expectedVersion: number): Promise<boolean> {
    if (typeof this.store.compareAndSetState === "function") return this.store.compareAndSetState(state, expectedVersion);
    await this.store.setState(state);
    return true;
  }

  /**
   * Runs a function as a recorded run. The function always runs, whatever
   * the store is doing: store errors go to onError, and the result is the
   * function's own outcome. Never throws for the job's own error; see `threw`.
   */
  private async execute<T>(definition: JobDefinition, fn: JobFn<T>, trigger: string): Promise<ExecuteResult<T>> {
    const name = definition.name;
    const startedAt = this.now();
    const run: Run = {
      id: crypto.randomUUID(),
      job: name,
      status: "running",
      startedAt,
      finishedAt: null,
      durationMs: null,
      error: null,
      output: null,
      metrics: {},
      trigger,
    };
    let recorded = false;
    try {
      await this.sync(definition);
      await this.store.insertRun({ ...run });
      recorded = true;
    } catch (e) {
      this.onError(e, `recording ${name}`);
    }
    // Closing missed and stuck happens beside the job, which never waits on it.
    const started = recorded
      ? this.updateState(name, (before) => ({ state: onRunStart(before), result: undefined }))
          .then(() => {}, (e) => this.onError(e, `starting ${name}`))
      : Promise.resolve();

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
    run.output = recorder.output() ?? (typeof result === "string" ? capOutput(result) : null);

    if (threw) {
      run.status = "failed";
      run.error = errorMessage(error);
    } else if (result instanceof Response && result.status >= 400) {
      run.status = "failed";
      run.error = `HTTP ${result.status}${result.statusText ? ` ${result.statusText}` : ""}`;
    } else {
      const expectText = recorder.expectText() ?? (typeof result === "string" ? result : null);
      const unmet = checkExpectation(definition.expect, expectText);
      if (unmet) {
        run.status = "failed";
        run.error = unmet;
      } else {
        run.status = "ok";
      }
    }
    // Redacted after the expect check, so a rule can still match what was
    // logged. NULs go last, so not even a custom redact can store one.
    if (run.output !== null) run.output = stripNul(this.redact(run.output));
    if (run.error !== null) run.error = stripNul(this.redact(run.error));

    await started;
    if (!recorded) {
      // The start was never written; the store may be back by now.
      try {
        await this.sync(definition);
        await this.store.insertRun(run);
        recorded = true;
      } catch (e) {
        this.onError(e, `recording ${name}`);
      }
      if (recorded) await this.finishRun(toStored(definition), run, finishedAt, false);
    } else if (await this.markedTimedOut(run)) {
      // A check gave up on this run while it was going and already counted it
      // as a stuck failure. A late failure must not count twice; a late
      // success still closes stuck and recovers.
      try {
        await this.store.updateRun(run);
      } catch (e) {
        this.onError(e, `recording ${name}`);
      }
    } else {
      await this.finishRun(toStored(definition), run, finishedAt, true);
    }

    return { run, result, error, threw };
  }

  /**
   * Record a run that happened outside this process, for a Source. Its job
   * must be declared with job() first. Runs are keyed by id: a new one is
   * inserted, a stored one still running is updated when this one is not,
   * and anything else is left alone, so recording the same run twice
   * changes nothing. A finished run is judged as if it had been wrapped
   * here (expect, failures, duration, budgets) and its output and error are
   * redacted the same way. Returns the alerts it sent.
   */
  async recordRun(input: Run, options: RecordRunOptions = {}): Promise<Alert[]> {
    const declared = this.definitions.get(input.job);
    if (!declared) throw new Error(`recordRun: job "${input.job}" is not declared; call job() first`);
    await this.sync(declared);
    const run: Run = { ...input, metrics: { ...input.metrics } };
    if (run.status === "ok") {
      const unmet = checkExpectation(declared.expect, run.output);
      if (unmet) {
        run.status = "failed";
        run.error = unmet;
      }
    }
    if (run.output !== null) run.output = stripNul(this.redact(capOutput(run.output)));
    if (run.error !== null) run.error = stripNul(this.redact(capOutput(run.error)));
    const evaluate = options.evaluate !== false;
    const definition = toStored(declared);

    const stored = await this.store.getRun(run.id);
    if (stored) {
      if (stored.status !== "running" || run.status === "running") return [];
      if (!evaluate) {
        await this.store.updateRun(run);
        return [];
      }
      return this.finishRun(definition, run, this.now(), true);
    }
    try {
      await this.store.insertRun(run);
    } catch (e) {
      // Another process recorded it first.
      if (await this.store.getRun(run.id).catch(() => null)) return [];
      throw e;
    }
    if (!evaluate) return [];
    await this.updateState(run.job, (before) => ({ state: onRunStart(before), result: undefined }));
    if (run.status === "running") return [];
    return this.finishRun(definition, run, this.now(), false);
  }

  /** Whether a check already marked this run as timed out, for a failure that finished late. */
  private async markedTimedOut(run: Run): Promise<boolean> {
    if (run.status === "ok") return false;
    try {
      return (await this.store.getRun(run.id))?.status === "timeout";
    } catch {
      return false;
    }
  }

  /**
   * Record a finished run (ok, failed, or timed out by a check), evaluate it
   * against the job's state and send what that produces. Never throws.
   */
  private async finishRun(definition: StoredJobDefinition, run: Run, now: number, write: boolean): Promise<Alert[]> {
    let drafts: AlertDraft[];
    try {
      if (write) await this.store.updateRun(run);
      let history: Run[] | null = null;
      ({ result: drafts } = await this.updateState(run.job, async (previous) => {
        history ??= await this.history(run);
        const settled = applySilence(previous, onRunFinish(definition, run, previous, history, now), now);
        return { state: settled.state, result: settled.alerts };
      }));
    } catch (e) {
      this.onError(e, `evaluating ${run.job}`);
      return [];
    }
    return this.dispatch(drafts, definition, now);
  }

  /**
   * The runs before `run`, newest first, with up to BASELINE_WINDOW
   * successful ones when the store has them. One small read normally; a
   * larger one only when failures crowd the successes out of it.
   */
  private async history(run: Run): Promise<Run[]> {
    let runs = await this.store.listRuns(run.job, HISTORY_PAGE);
    if (runs.length === HISTORY_PAGE && !hasFullBaseline(runs.filter((r) => r.id !== run.id))) {
      runs = await this.store.listRuns(run.job, HISTORY_MAX);
    }
    return runs.filter((r) => r.id !== run.id);
  }

  /**
   * Look for missed and stuck runs across every job, send alerts, retry
   * alerts no channel accepted, and prune old runs. Call it from an interval
   * (start()), a cron hitting the mounted routes, or by hand. Concurrent
   * calls share one check.
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
    const alerts: Alert[] = [];
    for (const source of this.sources) {
      try {
        alerts.push(...((await source.sync(this)) ?? []));
      } catch (e) {
        this.onError(e, `source ${source.name}`);
      }
    }
    for (const definition of this.definitions.values()) await this.sync(definition);
    const now = this.now();

    // Runs that never reported back. One that cannot be judged (its job's
    // stored timeout no longer parses, say) is reported and skipped.
    for (const run of await this.store.runningRuns()) {
      try {
        const declared = this.definitions.get(run.job);
        const definition = declared ? toStored(declared) : (await this.store.getJob(run.job))?.definition;
        if (!definition || !isStuck(definition, run, now)) continue;
        const timeout = timeoutMs(definition);
        run.status = "timeout";
        run.finishedAt = now;
        run.durationMs = now - run.startedAt;
        run.error = `Still running after ${formatDuration(timeout)}; marked as timed out`;
        alerts.push(...(await this.finishRun(definition, run, now, true)));
      } catch (e) {
        this.onError(e, `checking ${run.job}`);
      }
    }

    // Each job on its own: one that cannot be evaluated is reported, shown
    // as failing (see unevaluableSummary) and does not stop the others.
    const jobs: JobSummary[] = [];
    const retries = { spentMs: 0 };
    for (const stored of await this.store.listJobs()) {
      try {
        const recent = await this.store.listRuns(stored.name, BASELINE_WINDOW);
        let nextExpectedAt: number | null = null;
        const { state, result: drafts } = await this.updateState(stored.name, (previous) => {
          const evaluation = onCheck(stored.definition, stored, recent[0] ?? null, previous, now);
          nextExpectedAt = evaluation.nextExpectedAt;
          const settled = applySilence(previous, evaluation, now);
          return { state: settled.state, result: settled.alerts };
        });
        alerts.push(...(await this.retryUndelivered(stored.name, state, now, retries)));
        alerts.push(...(await this.dispatch(drafts, stored.definition, now)));
        jobs.push(summarize(stored, recent, state, nextExpectedAt, now));
      } catch (e) {
        this.onError(e, `checking ${stored.name}`);
        jobs.push(await this.unevaluable(stored, now));
      }
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

  /** A job's summary and its newest runs, without alerting. A job that cannot be evaluated is reported and shown as failing. */
  private async snapshot(stored: StoredJob, now: number, runs: number): Promise<{ job: JobSummary; runs: Run[] }> {
    let recent: Run[] = [];
    try {
      recent = await this.store.listRuns(stored.name, Math.max(runs, BASELINE_WINDOW));
      const state = await this.readState(stored.name);
      const { nextExpectedAt } = onCheck(stored.definition, stored, recent[0] ?? null, state, now);
      return { job: summarize(stored, recent, state, nextExpectedAt, now), runs: recent.slice(0, runs) };
    } catch (e) {
      this.onError(e, `reading ${stored.name}`);
      return { job: await this.unevaluable(stored, now), runs: recent.slice(0, runs) };
    }
  }

  /** The summary of a job whose evaluation failed, from whatever can still be read. */
  private async unevaluable(stored: StoredJob, now: number): Promise<JobSummary> {
    const recent = await this.store.listRuns(stored.name, BASELINE_WINDOW).catch((): Run[] => []);
    const state = await this.readState(stored.name).catch(() => emptyState(stored.name));
    return unevaluableSummary(stored, recent, state, now);
  }

  /** Every job the store knows about, with its health. Does not send alerts. */
  async jobs(): Promise<JobSummary[]> {
    return (await this.jobsWithRuns(0)).map((entry) => entry.job);
  }

  /** Every job's summary with its newest `limit` runs, read together. What the dashboard shows. */
  async jobsWithRuns(limit = 20): Promise<{ job: JobSummary; runs: Run[] }[]> {
    await this.ensureReady();
    for (const definition of this.definitions.values()) await this.sync(definition);
    const now = this.now();
    const out: { job: JobSummary; runs: Run[] }[] = [];
    for (const stored of await this.store.listJobs()) out.push(await this.snapshot(stored, now, clampLimit(limit, 20, 0)));
    return out;
  }

  async jobSummary(name: string): Promise<JobSummary | null> {
    await this.ensureReady();
    const definition = this.definitions.get(name);
    if (definition) await this.sync(definition);
    const stored = await this.store.getJob(name);
    if (!stored) return null;
    return (await this.snapshot(stored, this.now(), 0)).job;
  }

  /** A job's runs, newest first. `limit` is a whole number from 1 to 500. */
  async runs(name: string, limit = 50): Promise<Run[]> {
    await this.ensureReady();
    return this.store.listRuns(name, clampLimit(limit, 50, 1));
  }

  async getRun(id: string): Promise<Run | null> {
    await this.ensureReady();
    return this.store.getRun(id);
  }

  /** Stop alerts for a job for a while. State keeps updating underneath. */
  async silence(name: string, duration: Duration): Promise<JobState> {
    const ms = parseDuration(duration, "silence duration");
    return this.patchState(name, (state) => { state.silencedUntil = this.now() + ms; });
  }

  async unsilence(name: string): Promise<JobState> {
    return this.patchState(name, (state) => { state.silencedUntil = null; });
  }

  /** Read, change and write one job's state, in turn with every other update to it. */
  private async patchState(name: string, change: (state: JobState) => void): Promise<JobState> {
    await this.ensureReady();
    const { state } = await this.updateState(name, (current) => {
      const next = normalizeState(current, name);
      change(next);
      return { state: next, result: undefined };
    });
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
    if (this.deferDelivery && !this.warnedDeferredStart) {
      this.warnedDeferredStart = true;
      console.warn('[cronwatch] start() was called with deliver: "check", so these checks send no alerts. Another process must run checks with deliver: "now" (the default) to send them.');
    }
    const tick = () => this.check().catch((e) => this.onError(e, "check"));
    this.timer = setInterval(tick, ms);
    if (typeof this.timer === "object" && "unref" in this.timer) this.timer.unref();
    this.firstTick = setTimeout(() => {
      this.firstTick = null;
      void tick();
    }, 1_000);
    if (typeof this.firstTick === "object" && "unref" in this.firstTick) this.firstTick.unref();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    if (this.firstTick) clearTimeout(this.firstTick);
    this.timer = null;
    this.firstTick = null;
  }

  async close(): Promise<void> {
    this.stop();
    if (this.store.close) await this.store.close();
  }

  /**
   * Compose, triage and send each draft. The state was saved before this
   * (updateState), so a slow channel holds up nothing else; afterwards only
   * the delivery fields are written back, onto a fresh read of the state.
   */
  private async dispatch(drafts: AlertDraft[], definition: StoredJobDefinition, now: number): Promise<Alert[]> {
    if (drafts.length === 0) return [];
    const composed: Alert[] = [];
    const delivered: Alert[] = [];
    const failed: Alert[] = [];
    for (const draft of drafts) {
      const alert = composeAlert(draft, definition, now);
      if (this.deferDelivery) {
        failed.push(alert);
      } else {
        if (this.triage && alert.type !== "recovered") await this.addTriage(alert, TRIAGE_TIMEOUT_MS);
        (await this.deliver(alert) ? delivered : failed).push(alert);
      }
      composed.push(alert);
    }
    await this.recordDelivery(definition.name, delivered, failed, [], now);
    return composed;
  }

  /**
   * Send the alerts that no channel accepted last time, once each, oldest
   * first. `state` is the job's state as this check left it: an alert that
   * no longer describes it (staleAlert) is dropped instead. Retries across a
   * check share RETRY_BUDGET_MS of wall-clock time; once it is spent the rest
   * stay queued for the next check.
   */
  private async retryUndelivered(name: string, state: JobState, now: number, budget: { spentMs: number }): Promise<Alert[]> {
    const pending = state.undelivered ?? [];
    if (pending.length === 0 || isSilenced(state, now) || this.deferDelivery) return [];
    const delivered: Alert[] = [];
    const failed: Alert[] = [];
    const dropped = pending.filter((alert) => staleAlert(alert, state));
    for (const alert of pending) {
      if (dropped.includes(alert)) continue;
      const left = RETRY_BUDGET_MS - budget.spentMs;
      if (left <= 0) break;
      const started = Date.now();
      // An alert queued by a process that delivers at check time was never
      // triaged. One that was tried (triage: null) is not tried again.
      if (this.triage && alert.type !== "recovered" && alert.triage === undefined) await this.addTriage(alert, Math.min(TRIAGE_TIMEOUT_MS, left));
      (await this.deliver(alert) ? delivered : failed).push(alert);
      budget.spentMs += Math.max(0, Date.now() - started);
    }
    await this.recordDelivery(name, delivered, failed, dropped, now);
    return delivered;
  }

  /**
   * Mark delivered alerts done, drop stale ones, and keep failed ones for the
   * next check. A failed alert replaces its stored copy, so a triage made on
   * this attempt is kept. lastAlertAt moves only on a delivery.
   */
  private async recordDelivery(name: string, delivered: Alert[], failed: Alert[], dropped: Alert[], now: number): Promise<void> {
    try {
      const { result: trimmed } = await this.updateState(name, (previous) => {
        const state = normalizeState(previous, name);
        const done = new Set([...delivered, ...dropped].map(alertKey));
        const retried = new Map(failed.map((a) => [alertKey(a), a]));
        const kept = state.undelivered!.filter((a) => !done.has(alertKey(a))).map((a) => retried.get(alertKey(a)) ?? a);
        const known = new Set(kept.map(alertKey));
        kept.push(...failed.filter((a) => !known.has(alertKey(a))));
        state.undelivered = kept.slice(-MAX_UNDELIVERED);
        if (delivered.length > 0) state.lastAlertAt = now;
        return { state, result: Math.max(0, kept.length - MAX_UNDELIVERED) };
      });
      if (trimmed > 0) {
        this.onError(
          new Error(`${trimmed} undelivered alert${trimmed === 1 ? "" : "s"} for ${name} dropped: only the newest ${MAX_UNDELIVERED} are kept for retry`),
          `alert queue for ${name}`,
        );
      }
    } catch (e) {
      this.onError(e, `recording alert delivery for ${name}`);
    }
  }

  /** Send to every channel at once. True when at least one accepted it, or there are none. */
  private async deliver(alert: Alert): Promise<boolean> {
    if (this.alerts.length === 0) return true;
    const results = await Promise.all(
      this.alerts.map(async (channel) => {
        try {
          await withTimeout(channel.send(alert), CHANNEL_TIMEOUT_MS);
          return true;
        } catch (e) {
          this.onError(e, `alert channel ${channel.name}`);
          return false;
        }
      }),
    );
    return results.includes(true);
  }

  /** Sets alert.triage to the diagnosis, or to null when there is none, so it is tried once per alert. */
  private async addTriage(alert: Alert, timeout: number): Promise<void> {
    const controller = new AbortController();
    try {
      const recentRuns = await this.store.listRuns(alert.job, 5);
      const diagnosis = await withTimeout(this.triage!({ alert, recentRuns, signal: controller.signal }), timeout);
      alert.triage = typeof diagnosis === "string" && diagnosis !== "" ? diagnosis : null;
    } catch (e) {
      controller.abort();
      alert.triage = null;
      this.onError(e, `triage for ${alert.job}`);
    }
  }
}

function isDevelopment(): boolean {
  return process.env.NODE_ENV === "development" || process.env.NODE_ENV === "test";
}

/** A whole number in range, or the fallback for anything that is not a number. */
function clampLimit(limit: number, fallback: number, min: number): number {
  const n = typeof limit === "number" && Number.isFinite(limit) ? Math.trunc(limit) : fallback;
  return Math.min(500, Math.max(min, n));
}

function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const t = setTimeout(() => reject(new Error(`timed out after ${ms}ms`)), ms);
    if (typeof t === "object" && "unref" in t) t.unref();
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
