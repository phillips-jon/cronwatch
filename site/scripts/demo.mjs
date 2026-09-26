// The real CronWatch dashboard with seeded runs, so the site can show the
// actual thing rather than a mockup. Needs packages/sdk built first.
//
//   node site/scripts/demo.mjs            serve it on http://localhost:4399/cronwatch/
//   node site/scripts/demo.mjs --capture  write src/demo/alerts.txt, mcp.json,
//                                         jobs.json and runs.json, which the
//                                         landing page quotes (run with TZ=UTC)
import { createServer } from "node:http";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { cronwatch, memory, parseSchedule, nextFire } from "../../packages/sdk/dist/index.js";

const MIN = 60_000, HOUR = 3_600_000;
let clock = Date.now();
const printed = [];
const cw = cronwatch({
  store: memory(),
  alerts: [{ name: "record", send: async (alert) => { printed.push(`[cronwatch] ${alert.title}\n${alert.message}`); } }],
  cronSecret: null,
  now: () => clock,
});

const jobs = {
  "nightly-report": cw.job("nightly-report", { schedule: "0 2 * * *", timezone: "UTC", grace: "15m", description: "Builds the PDF and emails it to finance" }),
  "sync-crm": cw.job("sync-crm", { schedule: "every 30m", grace: "5m" }),
  "invoice-run": cw.job("invoice-run", { schedule: "0 3 * * *", timezone: "UTC", grace: "10m", timeout: "20m" }),
  "embeddings-refresh": cw.job("embeddings-refresh", { schedule: "every 15m", grace: "3m" }),
  "daily-digest": cw.job("daily-digest", { schedule: "0 4 * * *", timezone: "UTC", budget: { cost: 2 }, tags: ["agent"] }),
  "backup-to-s3": cw.job("backup-to-s3", { schedule: "0 5 * * *", timezone: "UTC", timeout: "2h" }),
};

async function at(when, name, ms, fn) {
  clock = when;
  try {
    await jobs[name].run(async (job) => { clock += ms; return fn?.(job); });
  } catch {}
}

// The demo day always ends at 22:42:19 UTC, the latest one already past, so
// the night's jobs have all run (or failed to) whenever the capture is taken.
const endOfDay = new Date(); endOfDay.setUTCHours(22, 42, 19, 0);
if (endOfDay.getTime() > Date.now()) endOfDay.setUTCDate(endOfDay.getUTCDate() - 1);
const now = endOfDay.getTime();
const today = new Date(now); today.setUTCHours(0, 0, 0, 0);
const T = (h, m = 0, dayOffset = 0) => today.getTime() + dayOffset * 86_400_000 + h * HOUR + m * MIN;

for (let d = 7; d >= 1; d--) {
  await at(T(2, 0, -d), "nightly-report", 70_000 + d * 900, (j) => { j.log("Rendering 14 pages"); j.log("Report written: /reports/" + d + ".pdf"); j.metric("pages", 14); });
  await at(T(3, 0, -d), "invoice-run", 19_000 + d * 400, (j) => { j.log("Loading 1,204 open invoices"); j.log("Sent 37 invoices"); j.metric("invoices", 37); });
  await at(T(4, 0, -d), "daily-digest", 41_000, (j) => { j.metrics({ tokens: 28_000 + d * 500, cost: 0.62 + d * 0.01 }); j.log("Digest sent to 412 subscribers"); });
  await at(T(5, 0, -d), "backup-to-s3", 9 * MIN, (j) => { j.log("Uploaded 2.1 GB"); });
}
await at(T(2, 0), "nightly-report", 72_000, (j) => { j.log("Rendering 14 pages"); j.log("Report written: /reports/today.pdf"); j.metric("pages", 14); });
await at(T(3, 0), "invoice-run", 412, (j) => {
  j.log("Loading 1,204 open invoices");
  j.log("Connecting to billing database");
  // The shape of a real pg connection failure, without this machine's paths in the stack.
  const err = new Error("connect ECONNREFUSED 10.0.0.12:5432");
  err.stack = "Error: connect ECONNREFUSED 10.0.0.12:5432\n    at TCPConnectWrap.afterConnect [as oncomplete] (node:net:1615:16)";
  throw err;
});
await at(T(4, 0), "daily-digest", 44_000, (j) => { j.metrics({ tokens: 131_000, cost: 3.4 }); j.log("Digest sent to 412 subscribers"); });
for (let i = 12; i >= 1; i--) {
  await at(now - (i - 1) * 15 * MIN - 5 * MIN, "embeddings-refresh", 240_000 + i * 1000, (j) => { j.metric("documents", 1_800 + i); });
}
// sync-crm stops: its last run was 35m30s ago, so with a 5m grace its
// deadline passed 30s before the check below, which is when a server calling
// cw.start() would have said so.
for (let i = 5; i >= 1; i--) {
  await at(now - (i - 1) * 30 * MIN - 35 * MIN - 30_000, "sync-crm", 8_000, (j) => { j.metric("contacts", 120 + i); });
}
// A backup that is running right now.
clock = now - 2 * MIN;
jobs["backup-to-s3"].run(() => new Promise(() => {})).catch(() => {});
await new Promise((r) => setImmediate(r));
clock = now;
await cw.check();

const routes = cw.routes({ token: null, basePath: "/cronwatch" });

if (process.argv.includes("--capture")) {
  const here = path.dirname(fileURLToPath(import.meta.url));
  const out = path.join(here, "..", "src", "demo");
  mkdirSync(out, { recursive: true });
  writeFileSync(path.join(out, "alerts.txt"), printed.join("\n\n") + "\n");
  const jobsResponse = await routes.handler(new Request("http://localhost/cronwatch/api/jobs"));
  const { jobs: jobList } = await jobsResponse.json();
  writeFileSync(path.join(out, "jobs.json"), JSON.stringify({ capturedAt: clock, jobs: jobList }, null, 2) + "\n");

  // Every time each job was *due* today, from the same parser the library
  // uses, so the strip can show the cadence a job keeps and the slot it missed.
  const expectedFor = (definition, runs, from, to) => {
    const parsed = parseSchedule(definition.schedule, definition.timezone);
    const out = [];
    if (parsed.kind === "interval") {
      // Intervals are anchored to the last run, so anchor the grid to a real
      // one; otherwise the ticks would not line up with what happened.
      const anchor = runs.length ? runs[0].startedAt : from;
      for (let t = anchor; t >= from; t -= parsed.everyMs) out.unshift(t);
      for (let t = anchor + parsed.everyMs; t <= to; t += parsed.everyMs) out.push(t);
      return out;
    }
    let t = from - 1;
    for (let i = 0; i < 500; i++) {
      const next = nextFire(parsed, t, null);
      if (next == null || next > to) break;
      out.push(next);
      t = next;
    }
    return out;
  };

  // Every run of the day so far, per job, for the strip on the landing page.
  const dayStart = today.getTime();
  const dayRuns = [];
  for (const j of jobList) {
    const runs = (await cw.runs(j.name, 200))
      .filter((r) => r.startedAt >= dayStart)
      .map((r) => ({ startedAt: r.startedAt, finishedAt: r.finishedAt, status: r.status, durationMs: r.durationMs }))
      .sort((a, b) => a.startedAt - b.startedAt);
    const expected = expectedFor(j.definition, runs, dayStart, dayStart + 86_400_000);
    dayRuns.push({ name: j.name, schedule: j.definition.schedule, health: j.health, open: j.open, missedAt: j.open.includes("missed") ? j.nextExpectedAt : null, runs, expected });
  }
  writeFileSync(path.join(out, "runs.json"), JSON.stringify({ capturedAt: clock, dayStart, jobs: dayRuns }, null, 2) + "\n");

  // A real exchange with the MCP server, over stdio, against this same data.
  const server = createServer(async (req, res) => {
    const r = await routes.handler(new Request(`http://localhost:4398${req.url}`, { method: req.method, headers: req.headers }));
    res.writeHead(r.status, Object.fromEntries(r.headers));
    res.end(Buffer.from(await r.arrayBuffer()));
  }).listen(4398, "127.0.0.1");
  const { Client } = await import("@modelcontextprotocol/sdk/client/index.js");
  const { StdioClientTransport } = await import("@modelcontextprotocol/sdk/client/stdio.js");
  const client = new Client({ name: "capture", version: "0" });
  await client.connect(new StdioClientTransport({
    command: process.execPath,
    args: [path.join(here, "..", "..", "packages", "mcp", "dist", "cli.js")],
    env: { ...process.env, CRONWATCH_URL: "http://127.0.0.1:4398/cronwatch" },
    stderr: "ignore",
  }));
  const exchange = [];
  for (const [name, args] of [["list_jobs", {}], ["get_job", { name: "invoice-run", runs: 1 }]]) {
    const result = await client.callTool({ name, arguments: args });
    exchange.push({ tool: name, arguments: args, reply: result.content.map((c) => c.text).join("\n") });
  }
  await client.close();
  server.close();
  writeFileSync(path.join(out, "mcp.json"), JSON.stringify(exchange, null, 2) + "\n");

  // After the capture: the fix ships, and the next night's invoice run succeeds.
  await at(T(3, 0, 1), "invoice-run", 19_600, (j) => { j.log("Loading 1,204 open invoices"); j.log("Sent 37 invoices"); j.metric("invoices", 37); });
  writeFileSync(path.join(out, "alerts.txt"), printed.join("\n\n") + "\n");
  console.log(`wrote ${out}/alerts.txt, mcp.json, jobs.json and runs.json`);
  await cw.close();
  process.exit(0);
}

createServer(async (req, res) => {
  clock = Date.now();
  const url = `http://localhost:4399${req.url}`;
  const request = new Request(url, { method: req.method, headers: req.headers });
  const response = await routes.handler(request);
  res.writeHead(response.status, Object.fromEntries(response.headers));
  res.end(Buffer.from(await response.arrayBuffer()));
}).listen(4399, "127.0.0.1", () => console.log("demo dashboard at http://localhost:4399/cronwatch/"));
