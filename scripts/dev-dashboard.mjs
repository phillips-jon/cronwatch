// A local CronWatch dashboard full of dummy jobs, for working on the pages.
// Seventeen jobs with a week of history in a memory store: healthy ones at
// several cadences, a failing job, a missed interval, a stuck run, a slow
// run, an over-budget job, a silenced job, one that never ran, and one with
// a long description and tags, and two with long framework-style names
// (a WordPress hook, a Laravel class). Nothing is saved; restart for a fresh week.
//
//   npm run dev:dashboard           serve on http://localhost:3717/cronwatch/
//   PORT=4000 npm run dev:dashboard
//
// Uses the built SDK, and builds it first when packages/sdk/dist is missing.
import { execSync } from "node:child_process";
import { existsSync } from "node:fs";
import { createServer } from "node:http";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const dist = path.join(root, "packages", "sdk", "dist", "index.js");
if (!existsSync(dist)) {
  console.log("packages/sdk is not built yet; building it");
  execSync("npm run build --workspace packages/sdk", { cwd: root, stdio: "inherit" });
}
const { cronwatch, memory } = await import(pathToFileURL(dist).href);

const PORT = Number(process.env.PORT || 3717);
const TOKEN = process.env.CRONWATCH_TOKEN || "cronwatch-dev";
const BASE = "/cronwatch";
const MIN = 60_000, HOUR = 60 * MIN, DAY = 24 * HOUR;

let clock = Date.now();
const cw = cronwatch({ store: memory(), alerts: [], cronSecret: null, now: () => clock });

/** A small, repeatable wobble, so durations and metrics look measured. */
let seed = 7;
const wobble = (spread) => { seed = (seed * 16807) % 2147483647; return 1 + ((seed / 2147483647) - 0.5) * 2 * spread; };

const job = (name, options) => cw.job(name, options);
const jobs = {
  "nightly-report": job("nightly-report", { schedule: "0 2 * * *", timezone: "UTC", grace: "15m", description: "Builds the PDF and emails it to finance" }),
  "sync-crm": job("sync-crm", { schedule: "every 15m", grace: "3m", description: "Pulls changed contacts from HubSpot" }),
  "heartbeat": job("heartbeat", { schedule: "every 5m", grace: "2m" }),
  "cache-warm": job("cache-warm", { schedule: "0 * * * *", timezone: "UTC", grace: "5m" }),
  "invoice-run": job("invoice-run", { schedule: "0 3 * * *", timezone: "UTC", grace: "10m", timeout: "20m", description: "Charges due invoices through Stripe" }),
  "import-orders": job("import-orders", { schedule: "every 30m", grace: "5m", description: "Imports marketplace orders" }),
  "video-transcode": job("video-transcode", { schedule: "*/20 * * * *", timezone: "UTC", timeout: "30m" }),
  "search-reindex": job("search-reindex", { schedule: "0 */6 * * *", timezone: "UTC", maxDuration: "10m", timeout: "1h" }),
  "daily-digest": job("daily-digest", { schedule: "0 4 * * *", timezone: "UTC", budget: { cost: 2 }, tags: ["agent"], description: "Summarises the day's tickets with Claude" }),
  "newsletter-send": job("newsletter-send", { schedule: "0 9 * * *", timezone: "UTC" }),
  "quarterly-report": job("quarterly-report", { schedule: "0 6 1 */3 *", timezone: "UTC", description: "Board pack for the quarter" }),
  "cleanup-sessions": job("cleanup-sessions", {
    schedule: "30 1 * * *", timezone: "UTC", tags: ["maintenance", "database", "gdpr"],
    description: "Deletes expired sessions and their rows in session_events, then vacuums both tables. Runs in batches of 5,000 so it never holds a lock for long; if it falls behind, the next run picks up where this one stopped.",
  }),
  "backup-to-s3": job("backup-to-s3", { schedule: "0 5 * * *", timezone: "UTC", timeout: "2h" }),
  "exchange-rates": job("exchange-rates", { schedule: "0 */4 * * *", timezone: "UTC", grace: "10m" }),
  "webhook-retry": job("webhook-retry", { schedule: "every 10m", grace: "3m" }),
  "wp:store_sync_inventory": job("wp:store_sync_inventory", { schedule: "0 * * * *", timezone: "UTC", grace: "5m" }),
  "App.Jobs.SendNewsletterDigest": job("App.Jobs.SendNewsletterDigest", { schedule: "0 7 * * *", timezone: "UTC" }),
};

async function at(when, name, ms, fn) {
  clock = when;
  try {
    await jobs[name].run(async (ctx) => { clock += ms; return fn?.(ctx); });
  } catch {}
}

const now = Date.now();
const midnight = Math.floor(now / DAY) * DAY;
/** Every time from `from` to `to` that lands on `every`, offset by `offset`. */
const slots = (every, from, to, offset = 0) => {
  const out = [];
  for (let t = Math.ceil((from - offset) / every) * every + offset; t < to; t += every) out.push(t);
  return out;
};

const seeded = [];
// Daily jobs over the last week, today's included when its hour has passed.
for (let d = 7; d >= 0; d--) {
  const day = midnight - d * DAY;
  const past = (t) => t < now - MIN;
  if (past(day + 2 * HOUR)) seeded.push([day + 2 * HOUR, "nightly-report", 70_000 * wobble(0.1), (j) => { j.log("Rendering 14 pages"); j.log("Report written"); j.metric("pages", 14); }]);
  if (past(day + 3 * HOUR)) {
    const failing = d <= 1;
    seeded.push([day + 3 * HOUR, "invoice-run", failing ? 1_800 : 19_000 * wobble(0.15), (j) => {
      j.log("Loading 1,204 open invoices");
      if (!failing) { j.log("Charged 37 invoices"); j.metric("invoices", 37); return; }
      j.log("Charging batch 1 of 3");
      const err = new Error("StripeCardError: Your card's security code is incorrect. (request req_9fQx2Lk, invoice in_1PzQ8A)");
      err.stack = `${err.message}\n    at chargeInvoice (app/jobs/invoice-run.ts:48:11)\n    at async Promise.all (index 3)\n    at async run (app/jobs/invoice-run.ts:22:5)`;
      throw err;
    }]);
  }
  if (past(day + 4 * HOUR)) {
    const today = d === 0 || (d === 1 && now - midnight < 4 * HOUR);
    seeded.push([day + 4 * HOUR, "daily-digest", 42_000 * wobble(0.1), (j) => {
      j.metrics(today ? { tokens: 131_000, cost: 3.4 } : { tokens: Math.round(29_000 * wobble(0.1)), cost: Number((0.64 * wobble(0.1)).toFixed(2)) });
      j.log("Digest sent to 412 subscribers");
    }]);
  }
  if (past(day + 5 * HOUR)) seeded.push([day + 5 * HOUR, "backup-to-s3", 9 * MIN * wobble(0.1), (j) => { j.log("Uploaded 2.1 GB"); j.metric("gb", 2.1); }]);
  if (past(day + 9 * HOUR)) seeded.push([day + 9 * HOUR, "newsletter-send", 3 * MIN * wobble(0.2), (j) => { j.log("Queued 18,204 emails"); }]);
  if (past(day + 7 * HOUR)) seeded.push([day + 7 * HOUR, "App.Jobs.SendNewsletterDigest", 50_000 * wobble(0.2)]);
  if (past(day + 90 * MIN)) seeded.push([day + 90 * MIN, "cleanup-sessions", 4 * MIN * wobble(0.3), (j) => { j.log("Deleted 48,112 sessions in 10 batches"); j.metric("deleted", 48_112); }]);
}
// Hourly, four-hourly, and six-hourly jobs over three days.
for (const t of slots(HOUR, now - 3 * DAY, now - MIN)) seeded.push([t, "cache-warm", 40_000 * wobble(0.2), (j) => j.metric("keys", 3_200)]);
for (const t of slots(HOUR, now - 3 * DAY, now - MIN)) seeded.push([t, "wp:store_sync_inventory", 12_000 * wobble(0.3), (j) => j.metric("products", 840)]);
for (const t of slots(4 * HOUR, now - 7 * DAY, now - MIN)) seeded.push([t, "exchange-rates", 2_500 * wobble(0.3), (j) => { j.metrics({ currencies: 32 }); j.log("Fetched 32 rates from ECB"); }]);
const reindex = slots(6 * HOUR, now - 7 * DAY, now - MIN);
reindex.forEach((t, i) => seeded.push([t, "search-reindex", i === reindex.length - 1 ? 26 * MIN : 6 * MIN * wobble(0.15), (j) => j.metric("documents", 412_000)]));
// Twenty-minute transcodes that ran fine, until the one that is stuck now.
for (const t of slots(20 * MIN, now - 2 * DAY, now - 2 * HOUR - 20 * MIN)) seeded.push([t, "video-transcode", 6 * MIN * wobble(0.3), (j) => j.metric("videos", 3)]);
// Intervals: anchored to their own last run.
for (let t = now - 4 * DAY; t < now - 60_000; t += 15 * MIN) seeded.push([t, "sync-crm", 8_000 * wobble(0.4), (j) => j.metric("contacts", 120)]);
for (let t = now - 2 * DAY + 30_000; t < now - 30_000; t += 5 * MIN) seeded.push([t, "heartbeat", 300 * wobble(0.5)]);
let retries = 0;
for (let t = now - 3 * DAY + 90_000; t < now - 60_000; t += 10 * MIN) {
  const fail = ++retries % 97 === 0;
  seeded.push([t, "webhook-retry", 1_200 * wobble(0.5), (j) => { j.log("Retried 4 webhooks"); if (fail) throw new Error("connect ETIMEDOUT 52.14.8.9:443"); }]);
}
// import-orders stopped an hour and a half ago.
for (let t = now - 3 * DAY; t < now - 95 * MIN; t += 30 * MIN) seeded.push([t, "import-orders", 20_000 * wobble(0.3), (j) => j.metric("orders", Math.round(40 * wobble(0.5)))]);

seeded.sort((a, b) => a[0] - b[0]);
for (const [when, name, ms, fn] of seeded) await at(when, name, Math.round(ms), fn);

// Stuck: a transcode that started two hours ago and never finished.
clock = now - 2 * HOUR;
jobs["video-transcode"].run(() => new Promise(() => {})).catch(() => {});
await new Promise((r) => setImmediate(r));
clock = now;
await cw.silence("newsletter-send", "1d");
await cw.check();

const routes = cw.routes({ token: TOKEN, basePath: BASE });
createServer(async (req, res) => {
  // Only the dashboard lives here; the browser's /favicon.ico and the like get a plain 404.
  const url = req.url ?? "/";
  if (url !== BASE && !url.startsWith(`${BASE}/`) && !url.startsWith(`${BASE}?`)) {
    res.writeHead(404, { "content-type": "text/plain" }).end("Not found. The dashboard is at " + BASE + "\n");
    return;
  }
  clock = Date.now();
  const chunks = [];
  for await (const c of req) chunks.push(c);
  const body = chunks.length && req.method !== "GET" && req.method !== "HEAD" ? Buffer.concat(chunks) : undefined;
  const headers = Object.fromEntries(Object.entries(req.headers).filter(([, v]) => typeof v === "string"));
  const response = await routes.handler(new Request(`http://localhost:${PORT}${req.url}`, { method: req.method, headers, body }));
  const out = {};
  response.headers.forEach((v, k) => { out[k] = v; });
  res.writeHead(response.status, out);
  res.end(Buffer.from(await response.arrayBuffer()));
}).listen(PORT, "127.0.0.1", () => {
  console.log(`CronWatch dev dashboard, ${Object.keys(jobs).length} dummy jobs, ${seeded.length} runs`);
  console.log(`Sign in: http://localhost:${PORT}${BASE}/?token=${TOKEN}`);
});
