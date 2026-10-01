import { formatDuration, parseDuration } from "./duration.js";
import { isDevelopment, isProduction, readEnv } from "./env.js";
import {
  applySilence,
  BASELINE_WINDOW,
  emptyState,
  hasFullBaseline,
  holdAlerts,
  isSilenced,
  isStuck,
  MAX_UNDELIVERED,
  normalizeState,
  onCheck,
  onRunFinish,
  onRunStart,
  recordSent,
  releaseSending,
  runDuration,
  SEND_LEASE_MS,
  silenceEnd,
  staleAlert,
  stateVersion,
  summarize,
  timeoutMs,
  unevaluableSummary,
} from "./evaluate.js";
import type { Evaluation } from "./evaluate.js";
import { composeAlert } from "./format.js";
import { constantTimeEqual, json } from "./http.js";
import { createRecorder } from "./job.js";
import type { JobContext } from "./job.js";
import { capOutput, describeError, OUTPUT_CAP, redactAndCap, redactSecrets } from "./output.js";
import { parseSchedule } from "./schedule.js";
import { checkExpectation, readStoredJob, toStored } from "./serialize.js";
import { buildRoutes } from "./routes/index.js";
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
   * Vercel sends its cron requests with). An empty string counts as unset.
   * With no secret at all the handler answers 503 unless the app is in
   * development (the first of CRONWATCH_ENV, APP_ENV and NODE_ENV that is
   * set names "development", "dev", "local", "test" or "testing"). Pass
   * null to allow anyone.
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
  /**
   * Record a running run now and finish it later, perhaps from another
   * process (see resume()). Store failures go to onError; it never throws for
   * them. A run that is never finished is marked stuck by the first check
   * after the job's timeout.
   */
  start(options?: StartOptions): Promise<RunHandle>;
  /** A handle on a run this job started elsewhere, by its id, so this process can log to it and finish it. */
  resume(runId: string): Promise<RunHandle>;
}

export interface StartOptions {
  /** What started the run, as with run(). Default "start". */
  trigger?: string;
  /**
   * Your own stable id for the run, such as an Inngest run id, 1 to 200
   * characters, not starting with "pgcron:" (the pg_cron source's). A start
   * with an id already recorded for this job records nothing and returns a
   * handle on that run instead; an id recorded for another job throws,
   * whether that job's start is still in flight or long done.
   */
  id?: string;
}

/**
 * How a started run ended. `{ error }` is a failure, recorded like an error
 * run() caught. Otherwise the run succeeded, and `result` (or a string
 * passed on its own) is treated like the value run()'s function returns:
 * a string is the output when nothing was logged, `expect` is checked, and
 * a Response with status 400 or above is a failure.
 */
export type RunOutcome = { status?: "ok"; result?: unknown } | { error: unknown };

/** A run recorded by job.start() or found by job.resume(), to finish later. */
export interface RunHandle {
  readonly id: string;
  readonly job: string;
  /** When the run started; null when a resumed run could not be read. */
  readonly startedAt: number | null;
  /** False once finished, and from the start for a resumed run that already finished or does not exist. */
  readonly active: boolean;
  /** Add a line of output. Kept in the handle until flush() or finish(). */
  log(...parts: unknown[]): void;
  /** Report a number for this run. A later value for the same name replaces an earlier one. */
  metric(name: string, value: number): void;
  metrics(values: Record<string, number>): void;
  /**
   * Append the lines and metrics added so far to the stored run, which must
   * still be running and belong to this job. A read, change and write of the
   * run's row, written only while it is still running: two processes
   * appending to one run at the same moment can lose one's lines, but a flush
   * never undoes a finish. The first 16 KB of everything flushed stay in the
   * handle, so an expect rule at finish() sees an early line as run() would.
   */
  flush(): Promise<void>;
  /**
   * Finish the run, judge it like any other and send what that produces.
   * Resolves to the run as recorded, or null when nothing was recorded: the
   * run was already finished (here or elsewhere), was not found, or belongs
   * to another job, which is reported to onError. When several processes
   * finish one run, only the one whose write lands judges it. Never throws
   * for the store: a store that fails is reported, nothing is recorded, and
   * the handle stays active so finish() can be called again.
   */
  finish(outcome?: RunOutcome | string): Promise<Run | null>;
  /** finish({ error }). */
  fail(error: unknown): Promise<Run | null>;
}

/**
 * What a Source may use of the client: declare jobs, read the store, and
 * record runs it found elsewhere. A Cronwatch is one.
 */
export interface SourceHost {
  /** Declare a job, as Cronwatch.job(). Throws for an invalid name or option. */
  job(name: string, options?: JobOptions): unknown;
  /**
   * The definitions declared now, as Cronwatch.definedJobs(): a source reads
   * it to declare again a job forgotten since (the dashboard's forget), whose
   * definition has not changed. A host without it is taken to keep every
   * job the source declared.
   */
  definedJobs?(): { name: string }[];
  /** See Cronwatch.recordRun(). */
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

export interface CronwatchOptions {
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
   * process.env.CRON_SECRET (on Cloudflare Workers, which have no process,
   * pass env.CRON_SECRET); an empty string counts as unset. Pass null to
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

/** Alerts written with the state that opened their conditions, and how many older ones the queue let go. */
interface Held {
  alerts: Alert[];
  dropped: number;
}

function sameState(a: JobState, b: JobState): boolean {
  return JSON.stringify(a) === JSON.stringify(b);
}

export class Cronwatch {
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
  /** "check": queue alerts for another process's check instead of sending them. See CronwatchOptions.deliver. */
  private readonly deferDelivery: boolean;
  private readonly defaults: NonNullable<CronwatchOptions["defaults"]>;
  private readonly definitions = new Map<string, JobDefinition>();
  private readonly synced = new Set<string>();
  /** The tail of each job's queue of state updates. See serial(). */
  private readonly queues = new Map<string, Promise<void>>();
  /** The tail of each job's queue of declaration writes. See sync(). */
  private readonly syncing = new Map<string, Promise<void>>();
  /** start() calls with an id still in flight, so two at once in this process record one run. */
  private readonly starting = new Map<string, Promise<RunHandle>>();
  private ready: Promise<void> | null = null;
  private checking: Promise<CheckResult> | null = null;
  private lastPruneAt = 0;
  private timer: ReturnType<typeof setInterval> | null = null;
  private firstTick: ReturnType<typeof setTimeout> | null = null;
  private usingDefaultStore = false;
  private warnedNoSecret = false;
  private warnedDeferredStart = false;
  /** Stored jobs read with a definition that was not a JSON object (see readJob). */
  private readonly unreadable = new WeakSet<StoredJob>();

  constructor(options: CronwatchOptions = {}) {
    this.store = options.store ?? (this.usingDefaultStore = true, memory());
    this.alerts = options.alerts ?? [consoleChannel()];
    this.triage = options.triage;
    this.sources = options.sources ?? [];
    const secret = options.cronSecret === undefined ? readEnv("CRON_SECRET") : options.cronSecret;
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

  /** A handle on a run started elsewhere, as job(name).resume(runId). The job must be declared in this process. */
  resumeRun(name: string, runId: string): Promise<RunHandle> {
    const definition = this.definitions.get(name);
    if (!definition) return Promise.reject(new Error(`resumeRun: job "${name}" is not declared; call job() first`));
    return this.resumeHandle(definition, runId);
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
      start(options?: StartOptions): Promise<RunHandle> {
        return self.startRun(definition, options ?? {});
      },
      resume(runId: string): Promise<RunHandle> {
        return self.resumeHandle(definition, runId);
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
        if (this.usingDefaultStore && isProduction()) {
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

  /**
   * Writes the declaration of `definition`'s name as it stands, unless the
   * store has it. A handle kept from an earlier declaration writes the one
   * that replaced it, never its own over it, and one forgotten since writes
   * its own. The writes of one name take turns, in the order they were asked
   * for, so one still under way cannot land after a later one; and a name
   * declared again while its write was under way is still to be written. A
   * name is marked as written only while that same declaration stands, so a
   * forget that lands during the write (deleting the row after it) leaves
   * the name to be written again, as does one forgotten before it.
   *
   * With `confirm`, as a run starts, a name already written is read back:
   * another process may have forgotten the job since, and a job still
   * declared here comes back on its next run.
   */
  private async sync(definition: JobDefinition, confirm = false): Promise<void> {
    await this.ensureReady();
    const name = definition.name;
    if (this.synced.has(name)) {
      if (!confirm || (await this.store.getJob(name))) return;
      this.synced.delete(name);
    }
    await this.serial(name, async () => {
      if (this.synced.has(name)) return;
      const standing = this.definitions.get(name) ?? definition;
      await this.store.upsertJob(toStored(standing), this.now());
      if (this.definitions.get(name) === standing) this.synced.add(name);
    }, this.syncing);
  }

  /**
   * Every stored job, once each declaration has been written. A job declared
   * here that the store no longer has was forgotten by another process after
   * this one wrote it: it is written again, as its next run would, so it is
   * checked and shown while any process still declares it.
   */
  private async storedJobs(): Promise<StoredJob[]> {
    for (const definition of this.definitions.values()) await this.sync(definition);
    const jobs = await this.store.listJobs();
    const listed = new Set(jobs.map((job) => job.name));
    const missing = [...this.definitions.values()].filter((definition) => !listed.has(definition.name));
    if (missing.length === 0) return jobs.map((job) => this.readJob(job));
    for (const definition of missing) {
      // Not one forgotten here meanwhile.
      if (this.definitions.get(definition.name) !== definition) continue;
      this.synced.delete(definition.name);
      await this.sync(definition);
    }
    return (await this.store.listJobs()).map((job) => this.readJob(job));
  }

  /** A stored job read leniently (readStoredJob); one whose definition is unreadable is remembered, so that evaluating it throws. */
  private readJob(stored: StoredJob): StoredJob {
    const { job, readable } = readStoredJob(stored);
    if (!readable) this.unreadable.add(job);
    return job;
  }

  /** Throws for a job whose stored definition was not a JSON object: reported, and shown as failing, while the others carry on. */
  private evaluable(stored: StoredJob): void {
    if (this.unreadable.has(stored)) throw new Error(`job "${stored.name}": its stored definition is not a JSON object`);
  }

  /**
   * Runs `fn` after every earlier state update for the same job has settled,
   * so two runs (or a run and a check) in this process never read and write
   * the job's state over each other. Other processes are coordinated by
   * updateState() instead. sync() queues a job's declaration writes the same
   * way, in `syncing`.
   */
  private serial<T>(job: string, fn: () => Promise<T>, queues = this.queues): Promise<T> {
    const result = (queues.get(job) ?? Promise.resolve()).then(fn);
    const tail = result.then(() => {}, () => {});
    queues.set(job, tail);
    void tail.then(() => {
      if (queues.get(job) === tail) queues.delete(job);
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
        const version = stateVersion(current);
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
      await this.sync(definition, true);
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
    const clearTimer = after(timeoutMs(definition), () => recorder.abort());

    let result: T | undefined;
    let error: unknown;
    let threw = false;
    try {
      result = await fn(recorder.context);
    } catch (e) {
      error = e;
      threw = true;
    } finally {
      clearTimer();
    }

    const finishedAt = this.now();
    run.finishedAt = finishedAt;
    run.durationMs = runDuration(startedAt, finishedAt);
    run.metrics = recorder.metrics();
    run.output = recorder.output() ?? (typeof result === "string" ? result : null);
    this.conclude(definition, run, result, error, threw, recorder.expectText() ?? (typeof result === "string" ? result : null));

    await started;
    try {
      const ignored = await this.recordFinish(definition, run, recorded, finishedAt);
      if (ignored) this.report(new Error(`run ${run.id} of ${name} ${ignored}; ignored`), `finishing ${name}`);
    } catch (e) {
      this.onError(e, `recording ${name}`);
    }
    return { run, result, error, threw };
  }

  /**
   * Sets a finished run's status and error from how it ended, then redacts
   * its output and error and caps them, in that order. Shared by execute()
   * and RunHandle.finish().
   */
  private conclude(definition: JobDefinition, run: Run, result: unknown, error: unknown, threw: boolean, expectText: string | null): void {
    if (threw) {
      run.status = "failed";
      run.error = describeError(error);
    } else if (result instanceof Response && result.status >= 400) {
      run.status = "failed";
      run.error = `HTTP ${result.status}${result.statusText ? ` ${result.statusText}` : ""}`;
    } else {
      const unmet = checkExpectation(definition.expect, expectText);
      if (unmet) {
        run.status = "failed";
        run.error = unmet;
      } else {
        run.status = "ok";
      }
    }
    // Redacted after the expect check, so a rule can still match what was
    // logged, and before the cap, so the cut cannot keep half a secret. NULs
    // go last, so not even a custom redact can store one.
    if (run.output !== null) run.output = redactAndCap(run.output, this.redact);
    if (run.error !== null) run.error = redactAndCap(run.error, this.redact);
  }

  /**
   * Writes a finished run and evaluates it. `recorded` says whether its
   * start was written; if not, it is inserted now. Returns why nothing was
   * recorded (another process finished the run first, say), or null. Throws
   * when the store does, so a handle can be finished again. Shared by
   * execute() and RunHandle.finish().
   */
  private async recordFinish(definition: JobDefinition, run: Run, recorded: boolean, finishedAt: number): Promise<string | null> {
    if (!recorded) {
      // The start was never written; the store may be back by now.
      await this.sync(definition);
      try {
        await this.store.insertRun(run);
        await this.finishRun(toStored(definition), run, finishedAt);
        return null;
      } catch (e) {
        // Another process may have recorded a run with this id meanwhile.
        const stored = await this.store.getRun(run.id).catch(() => null);
        if (!stored) throw e;
        if (stored.job !== run.job) return `belongs to job "${stored.job}"`;
      }
    }
    const claim = await this.claimFinish(run);
    if ("ignored" in claim) return claim.ignored;
    if (!claim.lateAfterTimeout || run.status === "ok") await this.finishRun(toStored(definition), run, finishedAt);
    return null;
  }

  /** A conditional write (Store.updateRunIf), or for a store without one, a read then a plain write. */
  private async writeRunIf(run: Run, fromStatuses: Run["status"][]): Promise<boolean> {
    if (typeof this.store.updateRunIf === "function") return this.store.updateRunIf(run, fromStatuses);
    const stored = await this.store.getRun(run.id);
    if (!stored || !fromStatuses.includes(stored.status)) return false;
    await this.store.updateRun(run);
    return true;
  }

  /**
   * Writes a finished run over its stored row, only while that row is still
   * running, or else still marked timeout by a check. Only the process whose
   * write lands goes on to evaluate the run; for the others it returns why
   * nothing was written. `lateAfterTimeout` means a check already counted
   * the run as a stuck failure: a late failure must not count twice, while
   * a late success still closes stuck and recovers. Throws when the store does.
   */
  private async claimFinish(run: Run): Promise<{ lateAfterTimeout: boolean } | { ignored: string }> {
    if (await this.writeRunIf(run, ["running"])) return { lateAfterTimeout: false };
    if (await this.writeRunIf(run, ["timeout"])) return { lateAfterTimeout: true };
    const stored = await this.store.getRun(run.id);
    return { ignored: stored ? `was already finished as ${stored.status}` : "was not found" };
  }

  /** job.start(): records a running run and returns a handle to finish it. See JobHandle.start. */
  private async startRun(definition: JobDefinition, options: StartOptions): Promise<RunHandle> {
    const id = options.id;
    if (id === undefined) return this.recordStart(definition, options.trigger);
    checkRunId(definition.name, id, "start");
    // Keyed by job as well, so another job's start with the same id is not
    // handed this job's run: it fails as it would one call later.
    const key = `${definition.name}\n${id}`;
    const inFlight = this.starting.get(key);
    if (inFlight) return inFlight;
    const started = this.recordStart(definition, options.trigger, id).finally(() => {
      if (this.starting.get(key) === started) this.starting.delete(key);
    });
    this.starting.set(key, started);
    return started;
  }

  /**
   * The start of execute() without the function: the run is inserted and
   * missed and stuck close (onRunStart). A store that fails is reported and
   * the handle inserts the finished run instead, as execute() does.
   */
  private async recordStart(definition: JobDefinition, trigger = "start", id?: string): Promise<RunHandle> {
    const name = definition.name;
    if (id !== undefined) {
      let stored: Run | null = null;
      try {
        await this.ensureReady();
        stored = await this.store.getRun(id);
      } catch (e) {
        this.onError(e, `recording ${name}`);
      }
      if (stored) return this.existingHandle(definition, stored);
    }
    const run: Run = {
      id: id ?? crypto.randomUUID(),
      job: name,
      status: "running",
      startedAt: this.now(),
      finishedAt: null,
      durationMs: null,
      error: null,
      output: null,
      metrics: {},
      trigger,
    };
    let recorded = false;
    try {
      await this.sync(definition, true);
      await this.store.insertRun({ ...run });
      recorded = true;
    } catch (e) {
      // Another process may have started a run with this id first.
      const stored = id === undefined ? null : await this.store.getRun(id).catch(() => null);
      if (stored) return this.existingHandle(definition, stored);
      this.onError(e, `recording ${name}`);
    }
    if (recorded) {
      await this.updateState(name, (before) => ({ state: onRunStart(before), result: undefined }))
        .catch((e: unknown) => this.onError(e, `starting ${name}`));
    }
    return this.runHandle(definition, run.id, run, recorded, null);
  }

  /** job.resume() and cw.resumeRun(). A store that cannot be read is reported, and finish() reads it again. */
  private async resumeHandle(definition: JobDefinition, runId: string): Promise<RunHandle> {
    checkRunId(definition.name, runId, "resume");
    let stored: Run | null;
    try {
      await this.ensureReady();
      stored = await this.store.getRun(runId);
    } catch (e) {
      this.onError(e, `resuming ${definition.name}`);
      return this.runHandle(definition, runId, null, true, null);
    }
    if (!stored) return this.runHandle(definition, runId, null, true, "was not found");
    return this.existingHandle(definition, stored);
  }

  /** A handle on a stored run. One still running, or marked timeout by a check, can be finished. */
  private existingHandle(definition: JobDefinition, stored: Run): RunHandle {
    if (stored.job !== definition.name) {
      throw new Error(`run "${stored.id}" belongs to job "${stored.job}", not "${definition.name}"`);
    }
    const finished = stored.status === "ok" || stored.status === "failed";
    return this.runHandle(definition, stored.id, stored, true, finished ? `already finished as ${stored.status}` : null);
  }

  /**
   * The handle itself. `base` is the run as last known here, `recorded`
   * whether its start is in the store, and `inactive` why finish() has
   * nothing to do, or null. Lines and metrics wait in the handle until
   * flush() or finish() merges them onto a fresh read of the stored run.
   */
  private runHandle(definition: JobDefinition, id: string, base: Run | null, recorded: boolean, inactive: string | null): RunHandle {
    const self = this;
    const name = definition.name;
    const fresh = () => createRecorder({ id, job: name, startedAt: base?.startedAt ?? 0 } as Run);
    let recorder = fresh();
    let finished = inactive !== null;
    let finishCalled = false;
    /**
     * The first OUTPUT_CAP characters of every line flushed from this
     * handle, unredacted, or null before the first flush. The stored output
     * keeps only the tail, so without it an expect rule at finish() would
     * miss a line logged early, which run() would have seen.
     */
    let head: string | null = null;
    let queue: Promise<unknown> = Promise.resolve();
    const inTurn = <T>(fn: () => Promise<T>): Promise<T> => {
      const result = queue.then(fn);
      queue = result.catch(() => {});
      return result;
    };
    const ignored = (why: string) => self.report(new Error(`run ${id} of ${name} ${why}; ignored`), `finishing ${name}`);

    const finish = (outcome?: RunOutcome | string): Promise<Run | null> => {
      if (finishCalled) {
        ignored("was already finished by this handle");
        return Promise.resolve(null);
      }
      finishCalled = true;
      const wasInactive = finished;
      finished = true;
      // The store failed part way and nothing was recorded, so the handle can be finished again.
      const retryable = (error: unknown): null => {
        finishCalled = false;
        finished = false;
        self.report(error, `finishing ${name}`);
        return null;
      };
      return inTurn(async () => {
        if (wasInactive) {
          ignored(inactive!);
          return null;
        }
        let from = base;
        if (recorded) {
          try {
            from = (await self.store.getRun(id)) ?? base;
          } catch (e) {
            return retryable(e);
          }
        }
        if (!from) {
          ignored("was not found");
          return null;
        }
        if (from.job !== name) {
          ignored(`belongs to job "${from.job}"`);
          return null;
        }
        if (from.status === "ok" || from.status === "failed") {
          ignored(`was already finished as ${from.status}`);
          return null;
        }
        const failed = typeof outcome === "object" && outcome !== null && "error" in outcome;
        const result = typeof outcome === "string" ? outcome : failed ? undefined : outcome?.result;
        const error = failed ? (outcome as { error: unknown }).error : undefined;
        const finishedAt = self.now();
        const added = recorder.output() ?? (typeof result === "string" ? result : null);
        const run: Run = {
          ...from,
          status: "running",
          finishedAt,
          durationMs: runDuration(from.startedAt, finishedAt),
          error: null,
          // Capped by conclude(), after it is redacted.
          output: joinLines(from.output, added),
          metrics: { ...from.metrics, ...recorder.metrics() },
        };
        const expectText = joinLines(head, joinLines(from.output, recorder.expectText() ?? (typeof result === "string" ? result : null)));
        self.conclude(definition, run, result, error, failed, expectText);
        let why: string | null;
        try {
          why = await self.recordFinish(definition, run, recorded, finishedAt);
        } catch (e) {
          return retryable(e);
        }
        if (why) {
          ignored(why);
          return null;
        }
        return run;
      });
    };

    return {
      id,
      job: name,
      startedAt: base?.startedAt ?? null,
      get active() {
        return !finished;
      },
      log: (...parts: unknown[]) => recorder.context.log(...parts),
      metric: (metric: string, value: number) => recorder.context.metric(metric, value),
      metrics: (values: Record<string, number>) => recorder.context.metrics(values),
      flush: () => inTurn(async () => {
        if (finished || !recorded) return;
        const lines = recorder.output();
        const metrics = recorder.metrics();
        if (lines === null && Object.keys(metrics).length === 0) return;
        // Lines logged while this waits on the store go to a new recorder.
        const taken = recorder;
        recorder = fresh();
        const putBack = () => {
          const later = recorder;
          recorder = fresh();
          for (const text of [taken.expectText(), later.expectText()]) if (text !== null) recorder.context.log(text);
          recorder.context.metrics({ ...taken.metrics(), ...later.metrics() });
        };
        try {
          const stored = await self.store.getRun(id);
          // Not running: the lines stay here for finish(), which reports why it cannot record them.
          if (!stored || stored.status !== "running") return putBack();
          if (stored.job !== name) {
            putBack();
            self.report(new Error(`run ${id} of ${name} belongs to job "${stored.job}"; ignored`), `flushing ${name}`);
            return;
          }
          const output = lines === null ? stored.output : joinOutput(stored.output, redactAndCap(lines, self.redact));
          // Only over a row still running, so a flush never undoes a finish written meanwhile.
          if (!(await self.writeRunIf({ ...stored, output, metrics: { ...stored.metrics, ...metrics } }, ["running"]))) return putBack();
          const text = taken.expectText();
          if (text !== null && (head === null || head.length < OUTPUT_CAP)) head = (joinLines(head, text) ?? "").slice(0, OUTPUT_CAP);
        } catch (e) {
          putBack();
          self.report(e, `flushing ${name}`);
        }
      }),
      finish,
      fail: (error: unknown) => finish({ error }),
    };
  }

  /**
   * Record a run that happened outside this process, for a Source. Its job
   * must be declared with job() first. Runs are keyed by id: a new one is
   * inserted, a stored one still running (or marked timeout by a check) is
   * finished when this one is not running, and anything else is left alone,
   * so recording the same run twice changes nothing. Finishing is
   * conditional (see Store.updateRunIf): when two processes record the same
   * finish, only the one whose write lands evaluates it, and the other
   * reports it as already finished. A stored run of another job is left
   * alone and reported. A finished run is judged as if it had been wrapped
   * here (expect, failures, duration, budgets) and its output and error are
   * redacted the same way; one finishing after a check marked it timeout is
   * judged only when it succeeded, as RunHandle.finish() does. A metric that
   * is not a finite number throws before anything is written, as
   * job.metric() does. Returns the alerts it sent.
   */
  async recordRun(input: Run, options: RecordRunOptions = {}): Promise<Alert[]> {
    const declared = this.definitions.get(input.job);
    if (!declared) throw new Error(`recordRun: job "${input.job}" is not declared; call job() first`);
    // The longest id start() takes; MySQL's column would hold 255, but every store holds 200.
    if (typeof input.id !== "string" || input.id.length === 0 || input.id.length > MAX_RUN_ID) {
      const got = typeof input.id === "string" ? `${input.id.length} characters` : typeof input.id;
      throw new Error(`recordRun: run ids must be 1 to ${MAX_RUN_ID} characters (got ${got}; job "${input.job}")`);
    }
    if (input.id.includes("\u0000")) throw new Error(`recordRun: run ids cannot contain a NUL character (job "${input.job}")`);
    // Refused as job.metric() refuses them: a store keeps NaN and Infinity as null.
    for (const [metric, value] of Object.entries(input.metrics ?? {})) {
      if (typeof value !== "number" || !Number.isFinite(value)) {
        throw new Error(`recordRun: metric "${metric}" must be a finite number (job "${input.job}", run "${input.id}")`);
      }
    }
    await this.sync(declared);
    const run: Run = { ...input, metrics: { ...input.metrics } };
    if (run.status === "ok") {
      const unmet = checkExpectation(declared.expect, run.output);
      if (unmet) {
        run.status = "failed";
        run.error = unmet;
      }
    }
    if (run.output !== null) run.output = redactAndCap(run.output, this.redact);
    if (run.error !== null) run.error = redactAndCap(run.error, this.redact);
    const evaluate = options.evaluate !== false;
    const definition = toStored(declared);

    const stored = await this.store.getRun(run.id);
    if (stored) return this.recordOver(definition, stored, run, evaluate);
    try {
      await this.store.insertRun(run);
    } catch (e) {
      // Another process recorded it first.
      const again = await this.store.getRun(run.id).catch(() => null);
      if (again) return this.recordOver(definition, again, run, evaluate);
      throw e;
    }
    if (!evaluate) return [];
    await this.updateState(run.job, (before) => ({ state: onRunStart(before), result: undefined }));
    if (run.status === "running") return [];
    return this.finishRun(definition, run, this.now());
  }

  /** recordRun() for a run already stored. */
  private async recordOver(definition: StoredJobDefinition, stored: Run, run: Run, evaluate: boolean): Promise<Alert[]> {
    if (stored.job !== run.job) {
      this.report(new Error(`run ${run.id} of ${run.job} belongs to job "${stored.job}"; ignored`), `recording ${run.job}`);
      return [];
    }
    if ((stored.status !== "running" && stored.status !== "timeout") || run.status === "running") return [];
    const claim = await this.claimFinish(run);
    if ("ignored" in claim) {
      this.report(new Error(`run ${run.id} of ${run.job} ${claim.ignored}; ignored`), `recording ${run.job}`);
      return [];
    }
    if (!evaluate || (claim.lateAfterTimeout && run.status !== "ok")) return [];
    return this.finishRun(definition, run, this.now());
  }

  /**
   * Evaluate a finished run (ok, failed, or timed out by a check), already
   * written, against the job's state and send what that produces. The
   * alerts are written with that state (see outbox()). Never throws.
   */
  private async finishRun(definition: StoredJobDefinition, run: Run, now: number): Promise<Alert[]> {
    let held: Held;
    try {
      let history: Run[] | null = null;
      ({ result: held } = await this.updateState(run.job, async (previous) => {
        history ??= await this.history(run);
        return this.outbox(applySilence(previous, onRunFinish(definition, run, previous, history, now), now), definition, now);
      }));
    } catch (e) {
      this.onError(e, `evaluating ${run.job}`);
      return [];
    }
    this.reportDropped(run.job, held.dropped);
    return this.dispatch(run.job, held.alerts, now);
  }

  /**
   * An evaluation as it is written: its drafts composed into alerts and held
   * in the same state (holdAlerts), so the write that opens a condition also
   * keeps its alerts, and a process that stops before sending them does not
   * lose them. Called inside updateState(), so it only computes.
   */
  private outbox(settled: Evaluation, definition: StoredJobDefinition, now: number): { state: JobState; result: Held } {
    const alerts = settled.alerts.map((draft) => composeAlert(draft, definition, now));
    const { state, dropped } = holdAlerts(settled.state, alerts, this.now() + SEND_LEASE_MS, this.deferDelivery);
    return { state, result: { alerts, dropped } };
  }

  /** Reports alerts let go because a job's queue was full. */
  private reportDropped(name: string, dropped: number): void {
    if (dropped <= 0) return;
    this.report(
      new Error(`${dropped} undelivered alert${dropped === 1 ? "" : "s"} for ${name} dropped: only the newest ${MAX_UNDELIVERED} are kept for retry`),
      `alert queue for ${name}`,
    );
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
    for (const listed of await this.store.runningRuns()) {
      try {
        const declared = this.definitions.get(listed.job);
        const found = declared ? null : await this.store.getJob(listed.job);
        const stored = found ? this.readJob(found) : null;
        if (stored) this.evaluable(stored);
        const definition = declared ? toStored(declared) : stored?.definition;
        if (!definition || !isStuck(definition, listed, now)) continue;
        // Read again just before the write: lines and metrics flushed since the
        // list was read (while earlier stuck runs were sent, say) are kept.
        const run = await this.store.getRun(listed.id);
        if (!run || run.status !== "running" || run.job !== listed.job) continue;
        const timeout = timeoutMs(definition);
        run.status = "timeout";
        run.finishedAt = now;
        run.durationMs = runDuration(run.startedAt, now);
        run.error = `Still running after ${formatDuration(timeout)}; marked as timed out`;
        // Only over a row still running: a finish that landed meanwhile wins.
        if (!(await this.writeRunIf(run, ["running"]))) continue;
        alerts.push(...(await this.finishRun(definition, run, now)));
      } catch (e) {
        this.onError(e, `checking ${listed.job}`);
      }
    }

    // Each job on its own: one that cannot be evaluated is reported, shown
    // as failing (see unevaluableSummary) and does not stop the others.
    const jobs: JobSummary[] = [];
    const retries = { spentMs: 0 };
    for (const stored of await this.storedJobs()) {
      try {
        this.evaluable(stored);
        const recent = await this.store.listRuns(stored.name, BASELINE_WINDOW);
        let nextExpectedAt: number | null = null;
        const { state, result: held } = await this.updateState(stored.name, (previous) => {
          const evaluation = onCheck(stored.definition, stored, recent[0] ?? null, previous, now);
          nextExpectedAt = evaluation.nextExpectedAt;
          const settled = applySilence(previous, evaluation, now);
          // Alerts a process stopped sending part way go back to the retry queue.
          const released = releaseSending(settled.state, this.now());
          const out = this.outbox({ state: released.state, alerts: settled.alerts }, stored.definition, now);
          return { state: out.state, result: { alerts: out.result.alerts, dropped: released.dropped + out.result.dropped } };
        });
        this.reportDropped(stored.name, held.dropped);
        alerts.push(...(await this.retryUndelivered(stored.name, state, now, retries)));
        alerts.push(...(await this.dispatch(stored.name, held.alerts, now)));
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
      this.evaluable(stored);
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
    const jobs = await this.storedJobs();
    const now = this.now();
    const out: { job: JobSummary; runs: Run[] }[] = [];
    for (const stored of jobs) out.push(await this.snapshot(stored, now, clampLimit(limit, 20, 0)));
    return out;
  }

  /** A job's summary, or null for one the store does not have. One declared here and forgotten elsewhere is written again, as storedJobs() does. */
  async jobSummary(name: string): Promise<JobSummary | null> {
    await this.ensureReady();
    const definition = this.definitions.get(name);
    if (definition) await this.sync(definition, true);
    const stored = await this.store.getJob(name);
    if (!stored) return null;
    return (await this.snapshot(this.readJob(stored), this.now(), 0)).job;
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

  /**
   * Stop alerts for a job for a while. State keeps updating underneath. The
   * end is a whole millisecond, held at 2^53 - 1 (see silenceEnd).
   */
  async silence(name: string, duration: Duration): Promise<JobState> {
    const ms = parseDuration(duration, "silence duration");
    return this.patchState(name, (state) => { state.silencedUntil = silenceEnd(this.now(), ms); });
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

  /**
   * Remove a job and its runs from the store. A job still declared in code
   * comes back: here on its next run, and in any other process that declares
   * it on its next run there, or at that process's next check or dashboard read.
   */
  async forget(name: string): Promise<void> {
    await this.ensureReady();
    this.definitions.delete(name);
    this.synced.delete(name);
    await this.store.deleteJob(name);
  }

  /**
   * The dashboard and JSON API as fetch-style handlers: the one way to mount
   * them. A Next.js app exports them from app/cronwatch/[[...path]]/route.ts:
   *
   *   export const { GET, POST, DELETE } = cw.routes();
   */
  routes(options?: RoutesOptions): Routes {
    return buildRoutes(this, options);
  }

  /**
   * Check on an interval, for long-running servers. Default every minute.
   * Not for serverless functions or Cloudflare Workers, where nothing runs
   * between requests: call check() from a cron there instead. (A job's
   * start() opens a run; this starts the checks.)
   */
  startChecking(every: Duration = "1m"): void {
    if (this.timer) return;
    // At most setInterval's longest delay: a longer one would check every millisecond.
    const ms = Math.min(TIMER_MAX_MS, Math.max(5_000, parseDuration(every, "check interval")));
    if (this.deferDelivery && !this.warnedDeferredStart) {
      this.warnedDeferredStart = true;
      console.warn('[cronwatch] startChecking() was called with deliver: "check", so these checks send no alerts. Another process must run checks with deliver: "now" (the default) to send them.');
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

  /**
   * startChecking(), under its former name.
   * @deprecated Renamed `startChecking`, since a job's `start()` opens a run.
   * This name still works through 1.x and goes in 2.0.
   */
  start(every: Duration = "1m"): void {
    this.startChecking(every);
  }

  /** Stop the checks startChecking() began. */
  stop(): void {
    if (this.timer) clearInterval(this.timer);
    if (this.firstTick) clearTimeout(this.firstTick);
    this.timer = null;
    this.firstTick = null;
  }

  /**
   * Stop the interval, wait for a check already under way (bounded by its
   * own channel, triage and retry timeouts; what it throws was reported to
   * whoever started it), then close the store, so that check neither writes
   * after the store is closed nor loses the alerts it would queue.
   */
  async close(): Promise<void> {
    this.stop();
    if (this.checking) await this.checking.catch(() => {});
    if (this.store.close) await this.store.close();
  }

  /**
   * Triage and send each alert the outbox holds (see outbox()). The state,
   * with the alerts in it, was saved before this, so a slow channel holds up
   * nothing else; afterwards only the delivery fields are written back, onto
   * a fresh read of the state, and the alerts leave `sending`. Triage is made
   * here, never stored with the held alert: the write that opens a condition
   * cannot wait for it, and a retry triages an alert that has none. With
   * deliver: "check" the alerts were queued for a check elsewhere instead.
   */
  private async dispatch(name: string, alerts: Alert[], now: number): Promise<Alert[]> {
    if (alerts.length === 0 || this.deferDelivery) return alerts;
    const delivered: Alert[] = [];
    const failed: Alert[] = [];
    for (const alert of alerts) {
      if (this.triage && alert.type !== "recovered") await this.addTriage(alert, TRIAGE_TIMEOUT_MS);
      (await this.deliver(alert) ? delivered : failed).push(alert);
    }
    await this.recordDelivery(name, delivered, failed, [], now);
    return alerts;
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
   * next check, taking them all out of `sending` (recordSent). A failed alert
   * replaces its stored copy, so a triage made on this attempt is kept.
   * lastAlertAt moves only on a delivery. When this write fails, alerts
   * still in `sending` are retried once their lease runs out.
   */
  private async recordDelivery(name: string, delivered: Alert[], failed: Alert[], dropped: Alert[], now: number): Promise<void> {
    try {
      const { result: trimmed } = await this.updateState(name, (previous) => {
        const { state, dropped: letGo } = recordSent(normalizeState(previous, name), delivered, failed, dropped, now);
        return { state, result: letGo };
      });
      this.reportDropped(name, trimmed);
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
          await withTimeout(channel.send(alert, { onError: (e) => this.report(e, `alert channel ${channel.name}`) }), CHANNEL_TIMEOUT_MS);
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

/** Run ids that start with this belong to the pg_cron source (see @cronwatch/sdk/pg-cron). */
export const RESERVED_RUN_ID_PREFIX = "pgcron:";

/**
 * The longest run id, in UTF-16 code units (JavaScript's string length): what
 * start(), resume() and recordRun() take, and every store holds.
 */
const MAX_RUN_ID = 200;

/** Throws for a run id no store could hold, or one reserved for the pg_cron source. */
function checkRunId(job: string, id: unknown, method: string): void {
  if (typeof id !== "string" || id.length === 0 || id.length > MAX_RUN_ID) {
    throw new Error(`job "${job}": ${method}() needs a run id of 1 to ${MAX_RUN_ID} characters (got ${typeof id === "string" ? `${id.length} characters` : typeof id})`);
  }
  // Postgres refuses NUL in text, so no store could hold such an id.
  if (id.includes("\u0000")) throw new Error(`job "${job}": ${method}() cannot take a run id containing a NUL character`);
  if (id.startsWith(RESERVED_RUN_ID_PREFIX)) {
    throw new Error(`job "${job}": ${method}() cannot take a run id starting with "${RESERVED_RUN_ID_PREFIX}", which the pg_cron source uses for its runs`);
  }
}

/** Two stretches of text as one, a line apart; either may be null. */
function joinLines(before: string | null, after: string | null): string | null {
  if (before === null || before === "") return after;
  if (after === null) return before;
  return `${before}\n${after}`;
}

/** Output appended to stored output, capped like any run's. */
function joinOutput(before: string | null, after: string | null): string | null {
  const joined = joinLines(before, after);
  return joined === null ? null : capOutput(joined);
}

/** A whole number in range, or the fallback for anything that is not a number. */
function clampLimit(limit: number, fallback: number, min: number): number {
  const n = typeof limit === "number" && Number.isFinite(limit) ? Math.trunc(limit) : fallback;
  return Math.min(500, Math.max(min, n));
}

/** The longest delay setTimeout keeps: Node runs a longer one after 1 ms. */
const TIMER_MAX_MS = 2 ** 31 - 1;

/**
 * Calls fn after ms, however long (a job's timeout of "30d" included, which
 * setTimeout alone would fire at once), without keeping the process alive.
 * Returns what cancels it.
 */
function after(ms: number, fn: () => void): () => void {
  let timer: ReturnType<typeof setTimeout>;
  const arm = (left: number): void => {
    timer = left > TIMER_MAX_MS ? setTimeout(() => arm(left - TIMER_MAX_MS), TIMER_MAX_MS) : setTimeout(fn, left);
    if (typeof timer === "object" && "unref" in timer) timer.unref();
  };
  arm(ms);
  return () => clearTimeout(timer);
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

/**
 * The client's former name.
 * @deprecated Renamed `Cronwatch`, the spelling every port uses. This name
 * still works through 1.x and goes in 2.0.
 */
export const CronWatch = Cronwatch;
/** @deprecated Renamed `Cronwatch`; this name goes in 2.0. */
export type CronWatch = Cronwatch;
/** @deprecated Renamed `CronwatchOptions`; this name goes in 2.0. */
export type CronWatchOptions = CronwatchOptions;
