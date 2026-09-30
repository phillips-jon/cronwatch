// Drives the Node SDK's SQLite store for the byte compatibility test
// (NodeCompatTest, after the Go and Rust ports'), from the built
// packages/sdk/dist, whose directory is the first argument.
//
//   node node_store.mjs <dist> write|read <path> <prefix> <fixture.json>
//   node node_store.mjs <dist> cas <path> <prefix> <state json> <expected version>
//
// write replays the fixture's store calls; read prints what the store hands
// back for the fixture's jobs and runs, as JSON on stdout; cas makes one
// compareAndSetState and prints whether it wrote, and the state after.
import { readFileSync } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const [dist, action, target, prefix, arg, expected] = process.argv.slice(2);
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
  }
} finally {
  await store.close();
}
process.stdout.write(JSON.stringify(out));
