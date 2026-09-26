// Captures what the SDK's routes answer for a fixed seed, so the gem's
// Cronwatch::Web can be compared with them byte for byte
// (test/web_golden_test.rb). Build the SDK first, then from the repo root:
//
//   npm run build --workspace packages/sdk
//   TZ=UTC node packages/ruby/test/web/golden.mjs
//
// The seed here and in web_golden_test.rb must stay the same, step for step.
import { createHash } from "node:crypto";
import { writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { cronwatch, custom, memory } from "../../../sdk/dist/index.js";

const T0 = Date.UTC(2026, 0, 5, 9, 30, 0);
const MIN = 60_000;
const HOUR = 3_600_000;
const DAY = 24 * HOUR;

let now = T0;
const cw = cronwatch({ now: () => now, store: memory(), alerts: [custom("capture", () => {})], cronSecret: null });

async function quietly(promise) {
  try {
    await promise;
  } catch {
    // A failed run is part of the seed.
  }
}

const nightly = cw.job("nightly-report", {
  schedule: "0 2 * * *", timezone: "UTC", grace: "15m", maxDuration: "10m", budget: { cost: 2 },
  expect: "Report written", failuresBeforeAlert: 2, description: "Builds the <b>PDF</b>", tags: ["reports", "<t>"],
});
const durations = [2000, 2500, 90_000, 3100, 1800];
for (let i = 0; i < durations.length; i++) {
  now = T0 - (5 - i) * DAY - 7 * HOUR - 30 * MIN;
  await quietly(nightly.run((job) => {
    job.log(i === 3 ? "Wrote nothing" : "Report written:", `report-${i}.pdf`);
    job.metric("cost", i === 4 ? 2.5 : 1.2);
    job.metric("rows", 40 + i);
    job.metric("2", 0.123456);
    now += durations[i];
  }));
}

const broken = cw.job("broken", { expect: "done" });
now = T0 - 2 * HOUR;
await quietly(broken.run((job) => {
  job.log("half way <script>alert(1)</script>");
  now += 450;
}));

const sync = cw.job("sync-users", { schedule: "*/15 * * * *", grace: 60_000, timeout: "5m" });
now = T0 - 3 * HOUR;
await quietly(sync.run(() => {
  now += 12_345;
}));

cw.job("never-ran", { schedule: "0 * * * *" });
now = T0;

const routes = cw.routes({ token: "tok", basePath: "/cronwatch" });
const bearer = { authorization: "Bearer tok" };
const cookie = { cookie: `cronwatch_token=${createHash("sha256").update("cronwatch-cookie:tok").digest("hex")}` };
const json = { ...bearer, "content-type": "application/json" };

/** Each request: [method, path, headers, body]. {run:JOB:N} is the Nth newest run of JOB. */
const requests = [
  ["GET", "/cronwatch/api/jobs", bearer],
  ["GET", "/cronwatch/api/jobs/nightly-report?runs=3", bearer],
  ["GET", "/cronwatch/api/jobs/nightly-report", bearer],
  ["GET", "/cronwatch/api/jobs/broken?runs=abc", bearer],
  ["GET", "/cronwatch/api/runs/{run:nightly-report:0}", bearer],
  ["GET", "/cronwatch/api/runs/nope", bearer],
  ["GET", "/cronwatch/api/jobs/missing", bearer],
  ["GET", "/cronwatch/", bearer],
  ["GET", "/cronwatch/jobs/nightly-report", bearer],
  ["GET", "/cronwatch/jobs/broken", bearer],
  ["GET", "/cronwatch/jobs/never-ran", bearer],
  ["GET", "/cronwatch/jobs/missing", bearer],
  ["POST", "/cronwatch/api/check", bearer],
  ["GET", "/cronwatch/api/check", cookie],
  ["POST", "/cronwatch/api/jobs/sync-users/silence", json, JSON.stringify({ for: "2h" })],
  ["POST", "/cronwatch/api/jobs/sync-users/silence", json, JSON.stringify({ for: "forever" })],
  ["POST", "/cronwatch/api/jobs/sync-users/silence?for=1h30m", bearer],
  ["POST", "/cronwatch/api/jobs/ghost/silence", json, JSON.stringify({ for: "1h" })],
  ["GET", "/cronwatch/jobs/sync-users", bearer],
  ["GET", "/cronwatch/api/jobs", bearer],
  ["POST", "/cronwatch/api/jobs/sync-users/unsilence", bearer],
  ["GET", "/cronwatch/api/jobs"],
  ["GET", "/cronwatch/api/jobs", { authorization: "Bearer wrong" }],
  ["GET", "/cronwatch/"],
  ["GET", "/cronwatch/nope", bearer],
  ["GET", "/cronwatch/api/nope", bearer],
  ["GET", "/cronwatch/jobs/%zz", bearer],
  ["GET", "/cronwatch/api/jobs/%zz", bearer],
  ["GET", "/cronwatch/?token=tok&view=all"],
  ["GET", "/cronwatch/jobs/broken?token=tok"],
  ["POST", "/cronwatch/api/check", { ...bearer, origin: "https://evil.example" }],
  ["POST", "/cronwatch/jobs/broken/silence", { ...bearer, origin: "https://evil.example", "content-type": "application/x-www-form-urlencoded" }, "for=1h"],
  ["POST", "/cronwatch/jobs/broken/silence", { ...bearer, "content-type": "application/x-www-form-urlencoded", referer: "http://app.test/cronwatch/jobs/broken" }, "for=forever"],
  ["POST", "/cronwatch/jobs/broken/silence", { ...bearer, "content-type": "application/x-www-form-urlencoded", referer: "http://app.test/cronwatch/jobs/broken" }, "for=4h"],
  ["GET", "/cronwatch/jobs/broken", bearer],
  ["POST", "/cronwatch/jobs/broken/unsilence", { ...bearer, referer: "https://evil.example/x" }],
  ["POST", "/cronwatch/check", { ...bearer, referer: "http://app.test/cronwatch/" }],
  ["POST", "/cronwatch/jobs/broken/explode", bearer],
  ["DELETE", "/cronwatch/api/jobs/broken", bearer],
  ["DELETE", "/cronwatch/api/jobs/broken", bearer],
  ["POST", "/cronwatch/jobs/never-ran/forget", bearer],
  ["GET", "/cronwatch/api/jobs", bearer],
  ["GET", "/cronwatch/", bearer],
];

const captures = [];
for (const [method, template, headers = {}, body] of requests) {
  const path = await resolve(template);
  const response = await routes.handler(new Request(`http://app.test${path}`, { method, headers, body }));
  const responseHeaders = {};
  for (const [k, v] of response.headers) responseHeaders[k] = v;
  captures.push({ method, path: template, headers, body: body ?? null, status: response.status, responseHeaders, responseBody: await response.text() });
}

async function resolve(template) {
  const match = /\{run:([^:}]+):(\d+)\}/.exec(template);
  if (!match) return template;
  const runs = await cw.runs(match[1], 50);
  return template.replace(match[0], runs[Number(match[2])].id);
}

// Run ids are random: each becomes <id:N>, numbered in order of first appearance.
const ids = new Map();
const text = JSON.stringify(captures).replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/g, (id) => {
  if (!ids.has(id)) ids.set(id, `<id:${ids.size}>`);
  return ids.get(id);
});

const out = fileURLToPath(new URL("./golden.json", import.meta.url));
writeFileSync(out, `${JSON.stringify({ note: "Generated by golden.mjs from the SDK's routes. Do not edit.", t0: T0, captures: JSON.parse(text) }, null, 2)}\n`);
console.log(`wrote ${captures.length} captures to ${out}`);
await cw.close();
