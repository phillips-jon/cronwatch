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
      return [...jobs.values()].map(clone).sort((a, b) => a.name.localeCompare(b.name));
    },
    async deleteJob(name) {
      jobs.delete(name);
      states.delete(name);
      for (const [id, run] of runs) if (run.job === name) { runs.delete(id); order.delete(id); }
    },
    async insertRun(run) {
      runs.set(run.id, clone(run));
      order.set(run.id, ++seq);
    },
    async updateRun(run) {
      runs.set(run.id, clone(run));
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
      return [...runs.values()].filter((r) => r.status === "running").map(clone);
    },
    async getState(job) {
      const s = states.get(job);
      return s ? clone(s) : null;
    },
    async setState(state) {
      states.set(state.job, clone(state));
    },
    async prune(before) {
      let n = 0;
      for (const [id, run] of runs) {
        if (run.status !== "running" && run.startedAt < before) {
          runs.delete(id);
          order.delete(id);
          n++;
        }
      }
      return n;
    },
  };
}
