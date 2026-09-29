// Captures what the SDK's routes answer for a fixed seed, so the gem's
// Cronwatch::Web and the Python package's cronwatch.web can be compared with
// them byte for byte (test/web_golden_test.rb and
// packages/python/tests/test_web_golden.py). Build the SDK first, then from
// the repo root:
//
//   npm run build --workspace packages/sdk
//   TZ=UTC node packages/ruby/test/web/golden.mjs
//
// With --check it writes nothing and exits 1 when golden.json is stale
// (`npm run check:conformance`, part of `npm run check`, runs it that way).
//
// It also writes the Rust crate's copies of the pages' style sheet and the
// app shell's scripts (packages/rust/cronwatch/src/web/assets, read there
// with include_str!, since a published crate cannot reach outside its own
// directory) and the Elixir package's (packages/elixir/lib/cronwatch/web/
// assets, read when it compiles, for the same reason), taken from the
// captures, and --check fails when they differ.
//
// The seed here, in web_golden_test.rb and in test_web_golden.py must stay the same, step for step.
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { cronwatch, custom, memory } from "../../../sdk/dist/index.js";

if (process.env.TZ !== "UTC") {
  console.error("golden: run with TZ=UTC (npm run check:conformance does); the fixture depends on the time zone");
  process.exit(2);
}

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
  // The app shell, served without the token.
  ["GET", "/cronwatch/manifest.webmanifest"],
  ["GET", "/cronwatch/sw.js"],
  ["GET", "/cronwatch/app.js"],
  ["GET", "/cronwatch/offline"],
  ["GET", "/cronwatch/offline/", cookie],
  ["GET", "/cronwatch/icons/icon.svg"],
  ["GET", "/cronwatch/icons/maskable.svg"],
  ["GET", "/cronwatch/icons/icon-192.png"],
  ["GET", "/cronwatch/icons/icon-512.png"],
  ["GET", "/cronwatch/icons/maskable-512.png"],
  ["GET", "/cronwatch/icons/apple-touch-icon.png"],
  ["GET", "/cronwatch/icons/nope.png"],
  ["GET", "/cronwatch/icons/nope.png", bearer],
  ["POST", "/cronwatch/sw.js", bearer],
];

const captures = [];
for (const [method, template, headers = {}, body] of requests) {
  const path = await resolve(template);
  const response = await routes.handler(new Request(`http://app.test${path}`, { method, headers, body }));
  const responseHeaders = {};
  for (const [k, v] of response.headers) responseHeaders[k] = v;
  // PNGs are kept as base64, so the fixture stays text.
  const responseBody = responseHeaders["content-type"] === "image/png"
    ? `base64:${Buffer.from(await response.arrayBuffer()).toString("base64")}`
    : await response.text();
  captures.push({ method, path: template, headers, body: body ?? null, status: response.status, responseHeaders, responseBody });
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
const golden = `${JSON.stringify({ note: "Generated by golden.mjs from the SDK's routes. Do not edit.", t0: T0, captures: JSON.parse(text) }, null, 2)}\n`;
await cw.close();

// The Rust crate's and the Elixir package's assets, from the captures: the
// scripts as served, and the style sheet from inside the offline page's
// <style>.
const served = (path) => captures.find((c) => c.method === "GET" && c.path === path).responseBody;
const assetDirs = [
  ["Rust", fileURLToPath(new URL("../../../rust/cronwatch/src/web/assets/", import.meta.url))],
  ["Elixir", fileURLToPath(new URL("../../../elixir/lib/cronwatch/web/assets/", import.meta.url))],
];
const assets = [
  ["style.css", /<style>([\s\S]*?)<\/style>/.exec(served("/cronwatch/offline"))[1]],
  ["app.js", served("/cronwatch/app.js")],
  ["sw.js", served("/cronwatch/sw.js")],
];

if (process.argv.includes("--check")) {
  for (const [port, dir] of assetDirs) {
    const staleAssets = assets.filter(([name, text]) => {
      try {
        return readFileSync(dir + name, "utf8") !== text;
      } catch {
        return true;
      }
    });
    if (staleAssets.length) {
      console.error(`the ${port} dashboard's copies of ${staleAssets.map(([name]) => name).join(", ")} are stale. Regenerate them:\n  npm run build --workspace packages/sdk && TZ=UTC node packages/ruby/test/web/golden.mjs`);
      process.exit(1);
    }
  }
  let current = null;
  try {
    current = readFileSync(out, "utf8");
  } catch {
    // A missing file is as stale as a wrong one.
  }
  if (current !== golden) {
    console.error(`${out} is stale: the SDK's routes answer differently now. Regenerate it:\n  npm run build --workspace packages/sdk && TZ=UTC node packages/ruby/test/web/golden.mjs`);
    process.exit(1);
  }
  console.log(`golden.json is up to date (${captures.length} captures)`);
} else {
  writeFileSync(out, golden);
  for (const [, dir] of assetDirs) {
    mkdirSync(dir, { recursive: true });
    for (const [name, text] of assets) writeFileSync(dir + name, text);
  }
  console.log(`wrote ${captures.length} captures to ${out}`);
}
