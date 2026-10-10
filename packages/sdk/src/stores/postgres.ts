import pg from "pg";
import type { Store, StoredJob } from "../types.js";
import { params, rowToJob, rowToRun, rowToState, schema, statements, tablePrefix, updateRunIfSql, type JobRow, type RunRow, type StateRow } from "./sql.js";

export interface PostgresOptions {
  /** postgres://... Defaults to process.env.DATABASE_URL. */
  connectionString?: string;
  /** Bring your own pool instead. It is not closed by close(). */
  pool?: pg.Pool;
  /** Table name prefix: lowercase letters, digits, and underscores. Default "cronwatch_". */
  prefix?: string;
}

/**
 * Keeps everything in Postgres through the `pg` driver. For apps on Vercel,
 * Neon, Supabase, Railway, and the like, where there is no disk to keep a
 * SQLite file on. Times are stored as BIGINT epoch milliseconds.
 */
export function postgres(options: PostgresOptions = {}): Store {
  const p = tablePrefix(options.prefix);
  const sql = statements("postgres", p);
  const owned = !options.pool;
  const pool = options.pool ?? new pg.Pool({ connectionString: options.connectionString ?? process.env.DATABASE_URL });

  const transaction = async (work: (client: pg.PoolClient) => Promise<void>) => {
    const client = await pool.connect();
    try {
      await client.query("BEGIN");
      await work(client);
      await client.query("COMMIT");
    } catch (e) {
      await client.query("ROLLBACK");
      throw e;
    } finally {
      client.release();
    }
  };

  return {
    async init() {
      // Many instances starting at once would race CREATE TABLE IF NOT EXISTS, which Postgres can
      // reject with a unique violation on pg_type. A lock per prefix makes them take turns.
      await transaction(async (client) => {
        await client.query("SELECT pg_advisory_xact_lock(hashtext($1))", [`cronwatch:${p}`]);
        await client.query(schema("postgres", p));
      });
    },
    async upsertJob(definition, now) {
      await pool.query(sql.upsertJob, params.upsertJob(definition, now));
    },
    async getJob(name) {
      const { rows } = await pool.query<JobRow>(sql.getJob, [name]);
      return rows[0] ? rowToJob(rows[0]) : null;
    },
    async listJobs(): Promise<StoredJob[]> {
      const { rows } = await pool.query<JobRow>(sql.listJobs);
      return rows.map(rowToJob);
    },
    async deleteJob(name) {
      await transaction(async (client) => {
        await client.query(sql.deleteRuns, [name]);
        await client.query(sql.deleteState, [name]);
        await client.query(sql.deleteJob, [name]);
      });
    },
    async insertRun(run) {
      await pool.query(sql.insertRun, params.insertRun(run));
    },
    async updateRun(run) {
      await pool.query(sql.updateRun, params.updateRun(run));
    },
    async updateRunIf(run, fromStatuses) {
      if (fromStatuses.length === 0) return false;
      const result = await pool.query(updateRunIfSql("postgres", p, fromStatuses.length), params.updateRunIf(run, fromStatuses));
      return (result.rowCount ?? 0) > 0;
    },
    async getRun(id) {
      const { rows } = await pool.query<RunRow>(sql.getRun, [id]);
      return rows[0] ? rowToRun(rows[0]) : null;
    },
    async listRuns(job, limit) {
      const { rows } = await pool.query<RunRow>(sql.listRuns, [job, limit]);
      return rows.map(rowToRun);
    },
    async lastRun(job) {
      const { rows } = await pool.query<RunRow>(sql.listRuns, [job, 1]);
      return rows[0] ? rowToRun(rows[0]) : null;
    },
    async runningRuns() {
      const { rows } = await pool.query<RunRow>(sql.runningRuns);
      return rows.map(rowToRun);
    },
    async getState(job) {
      const { rows } = await pool.query<StateRow>(sql.getState, [job]);
      return rows[0] ? rowToState(rows[0]) : null;
    },
    async setState(state) {
      await pool.query(sql.setState, params.setState(state));
    },
    async compareAndSetState(state, expectedVersion) {
      const result = expectedVersion === 0
        ? await pool.query(sql.casInsert, params.casInsert(state))
        : await pool.query(sql.casUpdate, params.casUpdate(state, expectedVersion));
      return (result.rowCount ?? 0) > 0;
    },
    async prune(before) {
      const result = await pool.query(sql.prune, [before]);
      return result.rowCount ?? 0;
    },
    async close() {
      if (owned) await pool.end();
    },
  };
}
