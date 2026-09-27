import type { Store, StoredJob } from "../types.js";
import { params, rowToJob, rowToRun, rowToState, schema, statements, tablePrefix, updateRunIfSql, type JobRow, type RunRow, type StateRow } from "./sql.js";

/**
 * The parts of a Cloudflare D1 binding this store uses. Written out here so
 * the SDK needs nothing from @cloudflare/workers-types: a Worker's
 * `env.DB: D1Database` fits it as it is.
 */
export interface D1PreparedStatementLike {
  bind(...values: unknown[]): D1PreparedStatementLike;
  first(): Promise<unknown>;
  all(): Promise<{ results?: unknown[] }>;
  run(): Promise<{ meta?: { changes?: number } }>;
}

export interface D1DatabaseLike {
  prepare(query: string): D1PreparedStatementLike;
  batch(statements: D1PreparedStatementLike[]): Promise<unknown[]>;
}

export interface D1Options {
  /** Table name prefix: lowercase letters, digits and underscores. Default "cronwatch_". */
  prefix?: string;
  /**
   * Create the tables on first use (CREATE TABLE IF NOT EXISTS), once per
   * isolate. Default true. Pass false when a D1 migration creates them
   * instead (see the Cloudflare docs page for the file).
   */
  createTables?: boolean;
}

/** Databases (and prefixes) whose tables this isolate has already made sure of. */
const created = new WeakMap<object, Set<string>>();

/**
 * Keeps everything in Cloudflare D1, for Workers. D1 is SQLite, so this is
 * the SQLite store's schema, statements and row mapping over D1's
 * prepare, bind and batch. Create it where the binding is, inside the
 * handler: `d1(env.DB)`.
 */
export function d1(database: D1DatabaseLike, options: D1Options = {}): Store {
  if (!database || typeof database.prepare !== "function" || typeof database.batch !== "function") {
    throw new Error("cronwatch: d1() needs a D1 database binding, such as env.DB");
  }
  const p = tablePrefix(options.prefix);
  // D1 keeps its own tables under _cf_ and refuses writes to them.
  if (p.startsWith("_cf_")) throw new Error(`cronwatch: invalid table prefix ${JSON.stringify(p)}. D1 reserves names starting with _cf_.`);
  const sql = statements("sqlite", p);
  const createTables = options.createTables ?? true;

  const stmt = (text: string, values: unknown[] = []) => {
    const s = database.prepare(text);
    return values.length > 0 ? s.bind(...values) : s;
  };
  const first = async <T>(text: string, values: unknown[]): Promise<T | null> => ((await stmt(text, values).first()) as T | null) ?? null;
  const all = async <T>(text: string, values: unknown[] = []): Promise<T[]> => ((await stmt(text, values).all()).results ?? []) as T[];
  const changes = async (text: string, values: unknown[]): Promise<number> => (await stmt(text, values).run()).meta?.changes ?? 0;

  return {
    async init() {
      if (!createTables || created.get(database)?.has(p)) return;
      // exec() splits on newlines, so each statement goes in on its own, in one batch.
      const ddl = schema("sqlite", p).split(";").map((s) => s.trim()).filter(Boolean);
      await database.batch(ddl.map((s) => database.prepare(s)));
      // Remembered only once it worked, and as a flag rather than a promise,
      // so no invocation ever waits on another's unfinished I/O.
      let prefixes = created.get(database);
      if (!prefixes) created.set(database, (prefixes = new Set()));
      prefixes.add(p);
    },
    async upsertJob(definition, now) {
      await stmt(sql.upsertJob, params.upsertJob(definition, now)).run();
    },
    async getJob(name) {
      const r = await first<JobRow>(sql.getJob, [name]);
      return r ? rowToJob(r) : null;
    },
    async listJobs(): Promise<StoredJob[]> {
      return (await all<JobRow>(sql.listJobs)).map(rowToJob);
    },
    async deleteJob(name) {
      // A batch is one transaction.
      await database.batch([stmt(sql.deleteRuns, [name]), stmt(sql.deleteState, [name]), stmt(sql.deleteJob, [name])]);
    },
    async insertRun(run) {
      await stmt(sql.insertRun, params.insertRun(run)).run();
    },
    async updateRun(run) {
      await stmt(sql.updateRun, params.updateRun(run)).run();
    },
    async updateRunIf(run, fromStatuses) {
      if (fromStatuses.length === 0) return false;
      return (await changes(updateRunIfSql("sqlite", p, fromStatuses.length), params.updateRunIf(run, fromStatuses))) > 0;
    },
    async getRun(id) {
      const r = await first<RunRow>(sql.getRun, [id]);
      return r ? rowToRun(r) : null;
    },
    async listRuns(job, limit) {
      return (await all<RunRow>(sql.listRuns, [job, limit])).map(rowToRun);
    },
    async lastRun(job) {
      const r = await first<RunRow>(sql.listRuns, [job, 1]);
      return r ? rowToRun(r) : null;
    },
    async runningRuns() {
      return (await all<RunRow>(sql.runningRuns)).map(rowToRun);
    },
    async getState(job) {
      const r = await first<StateRow>(sql.getState, [job]);
      return r ? rowToState(r) : null;
    },
    async setState(state) {
      await stmt(sql.setState, params.setState(state)).run();
    },
    async compareAndSetState(state, expectedVersion) {
      const written = expectedVersion === 0
        ? await changes(sql.casInsert, params.casInsert(state))
        : await changes(sql.casUpdate, params.casUpdate(state, expectedVersion));
      return written > 0;
    },
    async prune(before) {
      return changes(sql.prune, [before]);
    },
  };
}
