import Database from "better-sqlite3";
import { chmodSync, mkdirSync } from "node:fs";
import path from "node:path";
import type { JobState, Run, Store, StoredJob, StoredJobDefinition } from "../types.js";

export interface SqliteOptions {
  /** File path. The directory is created if missing. ":memory:" works too. */
  path?: string;
  /** Bring your own open better-sqlite3 database instead. */
  database?: Database.Database;
}

interface JobRow { name: string; definition: string; created_at: number; updated_at: number }
interface RunRow {
  id: string; job: string; status: Run["status"]; started_at: number; finished_at: number | null;
  duration_ms: number | null; error: string | null; output: string | null; metrics: string; trigger: string;
}

function rowToRun(r: RunRow): Run {
  return {
    id: r.id, job: r.job, status: r.status, startedAt: r.started_at, finishedAt: r.finished_at,
    durationMs: r.duration_ms, error: r.error, output: r.output, metrics: JSON.parse(r.metrics), trigger: r.trigger,
  };
}

/**
 * Keeps everything in one SQLite file through better-sqlite3. The right
 * choice for a single server. WAL mode, so the app's reads never block on a
 * run being written.
 */
export function sqlite(options: SqliteOptions = {}): Store {
  let db: Database.Database | null = options.database ?? null;
  const file = options.path ?? "./data/cronwatch.db";

  const open = (): Database.Database => {
    if (db) return db;
    if (file !== ":memory:") {
      mkdirSync(path.dirname(file), { recursive: true });
    }
    db = new Database(file);
    if (file !== ":memory:") {
      try { chmodSync(file, 0o600); } catch { /* best effort: not every filesystem cares */ }
    }
    db.pragma("journal_mode = WAL");
    db.pragma("busy_timeout = 5000");
    db.pragma("synchronous = NORMAL");
    return db;
  };

  return {
    async init() {
      const d = open();
      d.exec(`
        CREATE TABLE IF NOT EXISTS cronwatch_jobs (
          name TEXT PRIMARY KEY,
          definition TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS cronwatch_runs (
          id TEXT PRIMARY KEY,
          job TEXT NOT NULL,
          status TEXT NOT NULL,
          started_at INTEGER NOT NULL,
          finished_at INTEGER,
          duration_ms INTEGER,
          error TEXT,
          output TEXT,
          metrics TEXT NOT NULL DEFAULT '{}',
          trigger TEXT NOT NULL DEFAULT 'run'
        );
        CREATE INDEX IF NOT EXISTS cronwatch_runs_job_started ON cronwatch_runs (job, started_at DESC);
        CREATE INDEX IF NOT EXISTS cronwatch_runs_running ON cronwatch_runs (status) WHERE status = 'running';
        CREATE TABLE IF NOT EXISTS cronwatch_state (
          job TEXT PRIMARY KEY,
          state TEXT NOT NULL
        );
      `);
    },
    async upsertJob(definition: StoredJobDefinition, now: number) {
      open().prepare(`
        INSERT INTO cronwatch_jobs (name, definition, created_at, updated_at) VALUES (?, ?, ?, ?)
        ON CONFLICT(name) DO UPDATE SET definition = excluded.definition, updated_at = excluded.updated_at
      `).run(definition.name, JSON.stringify(definition), now, now);
    },
    async getJob(name) {
      const r = open().prepare("SELECT * FROM cronwatch_jobs WHERE name = ?").get(name) as JobRow | undefined;
      return r ? { name: r.name, definition: JSON.parse(r.definition), createdAt: r.created_at, updatedAt: r.updated_at } : null;
    },
    async listJobs(): Promise<StoredJob[]> {
      const rows = open().prepare("SELECT * FROM cronwatch_jobs ORDER BY name").all() as JobRow[];
      return rows.map((r) => ({ name: r.name, definition: JSON.parse(r.definition), createdAt: r.created_at, updatedAt: r.updated_at }));
    },
    async deleteJob(name) {
      const d = open();
      d.transaction(() => {
        d.prepare("DELETE FROM cronwatch_runs WHERE job = ?").run(name);
        d.prepare("DELETE FROM cronwatch_state WHERE job = ?").run(name);
        d.prepare("DELETE FROM cronwatch_jobs WHERE name = ?").run(name);
      })();
    },
    async insertRun(run) {
      open().prepare(`
        INSERT INTO cronwatch_runs (id, job, status, started_at, finished_at, duration_ms, error, output, metrics, trigger)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      `).run(run.id, run.job, run.status, run.startedAt, run.finishedAt, run.durationMs, run.error, run.output, JSON.stringify(run.metrics), run.trigger);
    },
    async updateRun(run) {
      open().prepare(`
        UPDATE cronwatch_runs SET status = ?, finished_at = ?, duration_ms = ?, error = ?, output = ?, metrics = ? WHERE id = ?
      `).run(run.status, run.finishedAt, run.durationMs, run.error, run.output, JSON.stringify(run.metrics), run.id);
    },
    async getRun(id) {
      const r = open().prepare("SELECT * FROM cronwatch_runs WHERE id = ?").get(id) as RunRow | undefined;
      return r ? rowToRun(r) : null;
    },
    async listRuns(job, limit) {
      const rows = open().prepare("SELECT * FROM cronwatch_runs WHERE job = ? ORDER BY started_at DESC, rowid DESC LIMIT ?").all(job, limit) as RunRow[];
      return rows.map(rowToRun);
    },
    async lastRun(job) {
      const r = open().prepare("SELECT * FROM cronwatch_runs WHERE job = ? ORDER BY started_at DESC, rowid DESC LIMIT 1").get(job) as RunRow | undefined;
      return r ? rowToRun(r) : null;
    },
    async runningRuns() {
      const rows = open().prepare("SELECT * FROM cronwatch_runs WHERE status = 'running' ORDER BY started_at").all() as RunRow[];
      return rows.map(rowToRun);
    },
    async getState(job) {
      const r = open().prepare("SELECT state FROM cronwatch_state WHERE job = ?").get(job) as { state: string } | undefined;
      return r ? (JSON.parse(r.state) as JobState) : null;
    },
    async setState(state) {
      open().prepare(`
        INSERT INTO cronwatch_state (job, state) VALUES (?, ?)
        ON CONFLICT(job) DO UPDATE SET state = excluded.state
      `).run(state.job, JSON.stringify(state));
    },
    async prune(before) {
      const info = open().prepare("DELETE FROM cronwatch_runs WHERE status != 'running' AND started_at < ?").run(before);
      return info.changes;
    },
    async close() {
      if (db && !options.database) {
        db.close();
        db = null;
      }
    },
  };
}
