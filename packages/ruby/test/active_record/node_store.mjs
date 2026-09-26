// Drives the Node SDK's SQLite or Postgres store for the byte compatibility
// test (node_compat_test.rb), from the built packages/sdk/dist.
//
//   node node_store.mjs write|read sqlite|postgres <path or url> <prefix> <fixture.json>
//   node node_store.mjs cas sqlite|postgres <path or url> <prefix> <state.json> <expected version>
//
// write replays the fixture's store calls; read prints what the store hands
// back for the fixture's jobs and runs, as JSON on stdout; cas makes one
// compareAndSetState and prints whether it wrote, and the state after.
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const [action, dialect, target, prefix, fixturePath, expected] = process.argv.slice(2);
const dist = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../../sdk/dist");
const fixture = action === "cas" ? null : JSON.parse(readFileSync(fixturePath, "utf8"));

let store;
if (dialect === "sqlite") {
  const { sqlite } = await import(pathToFileURL(path.join(dist, "sqlite.js")).href);
  store = sqlite({ path: target, prefix });
} else {
  const { postgres } = await import(pathToFileURL(path.join(dist, "postgres.js")).href);
  store = postgres({ connectionString: target, prefix });
}

const out = {};
try {
  await store.init();
  if (action === "write") {
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
    const state = JSON.parse(fixturePath);
    out.written = await store.compareAndSetState(state, Number(expected));
    out.state = await store.getState(state.job);
  } else if (action === "read") {
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
