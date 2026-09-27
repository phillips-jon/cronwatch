import type { JobState, Run, Store, StoredJob, StoredJobDefinition } from "../types.js";

/**
 * Keeps everything in process memory. The default when no store is given,
 * good for tests and for trying the library out. State is gone on restart,
 * so a missed run cannot be noticed across one.
 */
export function memory(): Store {
  const jobs = new Map<string, StoredJob>();
  const runs = new Map<string, Run>();
  const order = new Map<string, number>();
  const states = new Map<string, JobState>();
  let seq = 0;

  const clone = <T>(v: T): T => JSON.parse(JSON.stringify(v));
  // Code unit order, as the SQL stores sort by bytes rather than by locale.
  const byName = (a: StoredJob, b: StoredJob) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0);

  return {
    async upsertJob(definition: StoredJobDefinition, now: number) {
      const existing = jobs.get(definition.name);
      jobs.set(definition.name, {
        name: definition.name,
        definition: clone(definition),
        createdAt: existing?.createdAt ?? now,
        updatedAt: now,
      });
    },
    async getJob(name) {
      const j = jobs.get(name);
      return j ? clone(j) : null;
    },
    async listJobs() {
      return [...jobs.values()].map(clone).sort(byName);
    },
    async deleteJob(name) {
      jobs.delete(name);
      states.delete(name);
      for (const [id, run] of runs) if (run.job === name) { runs.delete(id); order.delete(id); }
    },
    async insertRun(run) {
      // Like SQL's primary key: an id already recorded is refused, never overwritten.
      if (runs.has(run.id)) throw new Error(`run ${run.id} already exists`);
      runs.set(run.id, clone(run));
      order.set(run.id, ++seq);
    },
    async updateRun(run) {
      // Like SQL's UPDATE: a run that is gone (its job was forgotten) stays gone, and only these fields change.
      const existing = runs.get(run.id);
      if (!existing) return;
      const { status, finishedAt, durationMs, error, output, metrics } = clone(run);
      runs.set(run.id, { ...existing, status, finishedAt, durationMs, error, output, metrics });
    },
    async updateRunIf(run, fromStatuses) {
      const existing = runs.get(run.id);
      if (!existing || !fromStatuses.includes(existing.status)) return false;
      const { status, finishedAt, durationMs, error, output, metrics } = clone(run);
      runs.set(run.id, { ...existing, status, finishedAt, durationMs, error, output, metrics });
      return true;
    },
    async getRun(id) {
      const r = runs.get(id);
      return r ? clone(r) : null;
    },
    async listRuns(job, limit) {
      return [...runs.values()]
        .filter((r) => r.job === job)
        .sort((a, b) => b.startedAt - a.startedAt || order.get(b.id)! - order.get(a.id)!)
        .slice(0, limit)
        .map(clone);
    },
    async lastRun(job) {
      const list = await this.listRuns(job, 1);
      return list[0] ?? null;
    },
    async runningRuns() {
      return [...runs.values()]
        .filter((r) => r.status === "running")
        .sort((a, b) => a.startedAt - b.startedAt || order.get(a.id)! - order.get(b.id)!)
        .map(clone);
    },
    async getState(job) {
      const s = states.get(job);
      return s ? clone(s) : null;
    },
    async setState(state) {
      states.set(state.job, clone(state));
    },
    async compareAndSetState(state, expectedVersion) {
      if ((states.get(state.job)?.version ?? 0) !== expectedVersion) return false;
      states.set(state.job, clone(state));
      return true;
    },
    async prune(before) {
      // Each job's newest run is kept whatever its age: without it, a job
      // that runs less often than the retention looks like it never ran.
      const newest = new Map<string, number>();
      for (const run of runs.values()) newest.set(run.job, Math.max(newest.get(run.job) ?? -Infinity, run.startedAt));
      let n = 0;
      for (const [id, run] of runs) {
        if (run.status !== "running" && run.startedAt < before && run.startedAt < newest.get(run.job)!) {
          runs.delete(id);
          order.delete(id);
          n++;
        }
      }
      return n;
    },
  };
}
