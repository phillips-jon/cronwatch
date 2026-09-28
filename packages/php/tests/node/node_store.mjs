// Drives the Node SDK's SQLite store for the byte compatibility test
// (NodeCompatTest.php), from the built packages/sdk/dist.
//
//   node node_store.mjs write|read <path> <prefix> <fixture.json>
//   node node_store.mjs cas <path> <prefix> <state json> <expected version>
//   node node_store.mjs run <path> <prefix>
//
// write replays the fixture's store calls; read prints what the store hands
// back for the fixture's jobs and runs, as JSON on stdout; cas makes one
// compareAndSetState and prints whether it wrote, and the state after; run
// has a Node client run the every-5 job once and check, as a process
// sharing the database would.
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const [action, target, prefix, arg, expected] = process.argv.slice(2);
const dist = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../../sdk/dist");
const { sqlite } = await import(pathToFileURL(path.join(dist, "sqlite.js")).href);
const store = sqlite({ path: target, prefix });

const out = {};
try {
  await store.init();
  if (action === "write") {
    const fixture = JSON.parse(readFileSync(arg, "utf8"));
    const pruned = [];
    for (const step of fixture.ops) {
      switch (step.op) {
        case "upsertJob": await store.upsertJob(step.definition, step.now); break;
        case "insertRun": await store.insertRun(step.run); break;
        case "updateRun": await store.updateRun(step.run); break;
        case "setState": await store.setState(step.state); break;
        case "deleteJob": await store.deleteJob(step.name); break;
        case "prune": pruned.push(await store.prune(step.before)); break;
        default: throw new Error(`unknown op ${step.op}`);
      }
    }
    out.pruned = pruned;
  } else if (action === "cas") {
    const state = JSON.parse(arg);
    out.written = await store.compareAndSetState(state, Number(expected));
    out.state = await store.getState(state.job);
  } else if (action === "read") {
    const fixture = JSON.parse(readFileSync(arg, "utf8"));
    out.jobs = await store.listJobs();
    out.job = {};
    out.runs = {};
    out.limited = {};
    out.last = {};
    out.state = {};
    for (const name of fixture.read.jobs) {
      out.job[name] = await store.getJob(name);
      out.runs[name] = await store.listRuns(name, 100);
      out.limited[name] = await store.listRuns(name, 1);
      out.last[name] = await store.lastRun(name);
      out.state[name] = await store.getState(name);
    }
    out.running = await store.runningRuns();
    out.run = {};
    for (const id of fixture.read.runs) out.run[id] = await store.getRun(id);
  } else if (action === "run") {
    const { cronwatch } = await import(pathToFileURL(path.join(dist, "index.js")).href);
    const now = Number(arg);
    const cw = cronwatch({ store, now: () => now, alerts: [], cronSecret: null, onError: (e) => { throw e; } });
    await cw.job("every-5", { schedule: "every 5m", timeout: "2m", maxDuration: "90s" }).run((job) => { job.log("from node"); });
    const result = await cw.check();
    out.jobs = result.jobs.map((j) => j.name);
  }
} finally {
  await store.close();
}
process.stdout.write(JSON.stringify(out));
