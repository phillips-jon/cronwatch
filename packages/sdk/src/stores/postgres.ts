import pg from "pg";
import type { JobState, Run, Store, StoredJob, StoredJobDefinition } from "../types.js";

export interface PostgresOptions {
  /** postgres://... Defaults to process.env.DATABASE_URL. */
  connectionString?: string;
  /** Bring your own pool instead. It is not closed by close(). */
  pool?: pg.Pool;
  /** Table name prefix. Default "cronwatch_". */
  prefix?: string;
}

interface JobRow { name: string; definition: StoredJobDefinition; created_at: string | number; updated_at: string | number }
interface RunRow {
  id: string; job: string; status: Run["status"]; started_at: string | number; finished_at: string | number | null;
  duration_ms: string | number | null; error: string | null; output: string | null; metrics: Record<string, number>; trigger: string;
}

const num = (v: string | number | null): number | null => (v === null ? null : Number(v));

function rowToRun(r: RunRow): Run {
  return {
    id: r.id, job: r.job, status: r.status, startedAt: Number(r.started_at), finishedAt: num(r.finished_at),
    durationMs: num(r.duration_ms), error: r.error, output: r.output, metrics: r.metrics ?? {}, trigger: r.trigger,
  };
}

/**
 * Keeps everything in Postgres through the `pg` driver. For apps on Vercel,
 * Neon, Supabase, Railway and the like, where there is no disk to keep a
 * SQLite file on. Times are stored as BIGINT epoch milliseconds.
 */
export function postgres(options: PostgresOptions = {}): Store {
  const owned = !options.pool;
  const pool = options.pool ?? new pg.Pool({ connectionString: options.connectionString ?? process.env.DATABASE_URL });
  const p = (options.prefix ?? "cronwatch_").replace(/[^a-z0-9_]/gi, "");
  const JOBS = `${p}jobs`, RUNS = `${p}runs`, STATE = `${p}state`;

  return {
    async init() {
      await pool.query(`
        CREATE TABLE IF NOT EXISTS ${JOBS} (
          name TEXT PRIMARY KEY,
          definition JSONB NOT NULL,
          created_at BIGINT NOT NULL,
          updated_at BIGINT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS ${RUNS} (
          seq BIGSERIAL,
          id TEXT PRIMARY KEY,
          job TEXT NOT NULL,
          status TEXT NOT NULL,
          started_at BIGINT NOT NULL,
          finished_at BIGINT,
          duration_ms BIGINT,
          error TEXT,
          output TEXT,
          metrics JSONB NOT NULL DEFAULT '{}'::jsonb,
          trigger TEXT NOT NULL DEFAULT 'run'
        );
        CREATE INDEX IF NOT EXISTS ${RUNS}_job_started ON ${RUNS} (job, started_at DESC);
        CREATE INDEX IF NOT EXISTS ${RUNS}_running ON ${RUNS} (status) WHERE status = 'running';
        CREATE TABLE IF NOT EXISTS ${STATE} (
          job TEXT PRIMARY KEY,
          state JSONB NOT NULL
        );
      `);
    },
    async upsertJob(definition, now) {
      await pool.query(
        `INSERT INTO ${JOBS} (name, definition, created_at, updated_at) VALUES ($1, $2, $3, $3)
         ON CONFLICT (name) DO UPDATE SET definition = EXCLUDED.definition, updated_at = EXCLUDED.updated_at`,
        [definition.name, JSON.stringify(definition), now],
      );
    },
    async getJob(name) {
      const { rows } = await pool.query<JobRow>(`SELECT * FROM ${JOBS} WHERE name = $1`, [name]);
      const r = rows[0];
      return r ? { name: r.name, definition: r.definition, createdAt: Number(r.created_at), updatedAt: Number(r.updated_at) } : null;
    },
    async listJobs(): Promise<StoredJob[]> {
      const { rows } = await pool.query<JobRow>(`SELECT * FROM ${JOBS} ORDER BY name`);
      return rows.map((r) => ({ name: r.name, definition: r.definition, createdAt: Number(r.created_at), updatedAt: Number(r.updated_at) }));
    },
    async deleteJob(name) {
      const client = await pool.connect();
      try {
        await client.query("BEGIN");
        await client.query(`DELETE FROM ${RUNS} WHERE job = $1`, [name]);
        await client.query(`DELETE FROM ${STATE} WHERE job = $1`, [name]);
        await client.query(`DELETE FROM ${JOBS} WHERE name = $1`, [name]);
        await client.query("COMMIT");
      } catch (e) {
        await client.query("ROLLBACK");
        throw e;
      } finally {
        client.release();
      }
    },
    async insertRun(run) {
      await pool.query(
        `INSERT INTO ${RUNS} (id, job, status, started_at, finished_at, duration_ms, error, output, metrics, trigger)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)`,
        [run.id, run.job, run.status, run.startedAt, run.finishedAt, run.durationMs, run.error, run.output, JSON.stringify(run.metrics), run.trigger],
      );
    },
    async updateRun(run) {
      await pool.query(
        `UPDATE ${RUNS} SET status = $1, finished_at = $2, duration_ms = $3, error = $4, output = $5, metrics = $6 WHERE id = $7`,
        [run.status, run.finishedAt, run.durationMs, run.error, run.output, JSON.stringify(run.metrics), run.id],
      );
    },
    async getRun(id) {
      const { rows } = await pool.query<RunRow>(`SELECT * FROM ${RUNS} WHERE id = $1`, [id]);
      return rows[0] ? rowToRun(rows[0]) : null;
    },
    async listRuns(job, limit) {
      const { rows } = await pool.query<RunRow>(`SELECT * FROM ${RUNS} WHERE job = $1 ORDER BY started_at DESC, seq DESC LIMIT $2`, [job, limit]);
      return rows.map(rowToRun);
    },
    async lastRun(job) {
      const { rows } = await pool.query<RunRow>(`SELECT * FROM ${RUNS} WHERE job = $1 ORDER BY started_at DESC, seq DESC LIMIT 1`, [job]);
      return rows[0] ? rowToRun(rows[0]) : null;
    },
    async runningRuns() {
      const { rows } = await pool.query<RunRow>(`SELECT * FROM ${RUNS} WHERE status = 'running' ORDER BY started_at`);
      return rows.map(rowToRun);
    },
    async getState(job) {
      const { rows } = await pool.query<{ state: JobState }>(`SELECT state FROM ${STATE} WHERE job = $1`, [job]);
      return rows[0]?.state ?? null;
    },
    async setState(state) {
      await pool.query(
        `INSERT INTO ${STATE} (job, state) VALUES ($1, $2) ON CONFLICT (job) DO UPDATE SET state = EXCLUDED.state`,
        [state.job, JSON.stringify(state)],
      );
    },
    async prune(before) {
      const result = await pool.query(`DELETE FROM ${RUNS} WHERE status <> 'running' AND started_at < $1`, [before]);
      return result.rowCount ?? 0;
    },
    async close() {
      if (owned) await pool.end();
    },
  };
}
