import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { after, before, test } from "node:test";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";
import { Miniflare } from "miniflare";
import { d1, type D1DatabaseLike } from "../src/stores/d1.js";
import { schema } from "../src/stores/sql.js";
import type { Run } from "../src/types.js";
import { conformance } from "./store-conformance.js";

/**
 * Cloudflare Workers, in workerd through Miniflare. The sample Worker is
 * bundled the way wrangler bundles one (esbuild, the workerd conditions, no
 * Node built-ins) and run without nodejs_compat, so anything in the core that
 * reached for node:, process, or Buffer fails here.
 */

const HOUR = 3_600_000;
let mf: Miniflare;
let db: D1DatabaseLike;
let bundle: string;

before(async () => {
  const result = await build({
    entryPoints: [fileURLToPath(new URL("./workers/worker.ts", import.meta.url))],
    bundle: true,
    format: "esm",
    platform: "browser",
    conditions: ["workerd", "worker", "browser"],
    target: "es2022",
    write: false,
    logLevel: "silent",
  });
  bundle = result.outputFiles[0]!.text;
  mf = new Miniflare({
    modules: true,
    script: bundle,
    compatibilityDate: "2025-09-01",
    compatibilityFlags: [],
    d1Databases: ["DB"],
    bindings: { CRONWATCH_TOKEN: "tok", CRON_SECRET: "sec" },
    // The fallback request.cf, rather than fetching one from Cloudflare and caching it in .wrangler/.
    cf: false,
  });
  db = await mf.getD1Database("DB");
});

after(async () => {
  await mf?.dispose();
});

test("the core bundles for workerd with nothing from Node", () => {
  assert.doesNotMatch(bundle, /["']node:/, "no node: imports");
  assert.doesNotMatch(bundle, /\brequire\(/, "no require()");
  assert.doesNotMatch(bundle, /\bBuffer\b/, "no Buffer");
});

test("d1: store conformance, against D1 in Miniflare", async () => {
  await conformance("d1", () => d1(db, { prefix: "conf_" }));
});

test("d1: tables are made once per isolate, and not at all with createTables: false", async () => {
  const tables = async () => ((await db.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'once_%' ORDER BY name").all()).results as { name: string }[]).map((t) => t.name);
  await d1(db, { prefix: "once_", createTables: false }).init!();
  assert.deepEqual(await tables(), []);
  const store = d1(db, { prefix: "once_" });
  await store.init!();
  assert.deepEqual(await tables(), ["once_jobs", "once_runs", "once_state"]);
  await store.init!();
  await d1(db, { prefix: "once_" }).init!();
});

test("d1: a missing binding or a _cf_ prefix is refused", () => {
  assert.throws(() => d1(undefined as unknown as D1DatabaseLike), /D1 database binding/);
  assert.throws(() => d1(db, { prefix: "_cf_x_" }), /reserves/);
  assert.throws(() => d1(db, { prefix: "Bad" }), /invalid table prefix/);
});

test("the migration on the Cloudflare docs page is the schema the store makes", () => {
  const page = readFileSync(fileURLToPath(new URL("../../../site/docs/cloudflare.md", import.meta.url)), "utf8");
  const block = /```sql\n-- migrations\/0001_cronwatch\.sql\n([\s\S]*?)```/.exec(page);
  assert.ok(block, "the page has the migration block");
  const normalize = (text: string) => text.split(";").map((s) => s.replace(/\s+/g, " ").trim()).filter(Boolean);
  assert.deepEqual(normalize(block[1]!), normalize(schema("sqlite", "cronwatch_")));
});

async function runs(job: string): Promise<Run[]> {
  const res = await mf.dispatchFetch(`http://localhost/cronwatch/api/jobs/${job}`, { headers: { authorization: "Bearer tok" } });
  assert.equal(res.status, 200);
  return ((await res.json()) as { runs: Run[] }).runs;
}

async function alerts(): Promise<{ job: string; type: string }[]> {
  return (await db.prepare("SELECT job, type FROM test_alerts ORDER BY rowid").all()).results as { job: string; type: string }[];
}

test("end to end: a Cron Trigger run, a missed run found by the scheduled check, and the dashboard", async () => {
  await db.prepare("CREATE TABLE test_alerts (job TEXT, type TEXT, title TEXT)").run();
  // The hourly job has been declared for three hours and has never run.
  const store = d1(db);
  await store.init!();
  await store.upsertJob({ name: "hourly", schedule: "0 * * * *", grace: "5m" }, Date.now() - 3 * HOUR);

  // Typed here because the Fetcher type comes from @cloudflare/workers-types, which this repo does not install.
  const worker = (await mf.getWorker()) as unknown as { scheduled(options: { cron: string }): Promise<{ outcome: string }> };
  const nightly = await worker.scheduled({ cron: "0 2 * * *" });
  assert.equal(nightly.outcome, "ok");
  const [run] = await runs("nightly");
  assert.equal(run!.status, "ok");
  assert.equal(run!.trigger, "cron");
  assert.equal(run!.output, "rows: 3");
  assert.deepEqual(run!.metrics, { rows: 3 });

  const check = await worker.scheduled({ cron: "*/5 * * * *" });
  assert.equal(check.outcome, "ok");
  assert.deepEqual(await alerts(), [{ job: "hourly", type: "missed" }], "the check found the miss and delivered it inside waitUntil");
  const hourly = await (await mf.dispatchFetch("http://localhost/cronwatch/api/jobs/hourly", { headers: { authorization: "Bearer tok" } })).json() as { job: { health: string; open: string[] } };
  assert.equal(hourly.job.health, "late");
  assert.deepEqual(hourly.job.open, ["missed"]);

  // A second check opens nothing new.
  await worker.scheduled({ cron: "*/5 * * * *" });
  assert.equal((await alerts()).length, 1);

  // A failing run, from fetch this time.
  const failed = await mf.dispatchFetch("http://localhost/fail");
  assert.equal(failed.status, 500);
  assert.equal(await failed.text(), "upstream was down");
  assert.equal((await runs("nightly"))[0]!.status, "failed");
  assert.deepEqual((await alerts()).map((a) => `${a.job} ${a.type}`), ["hourly missed", "nightly failed"]);

  // The dashboard: locked without the token, signed in with it.
  assert.equal((await mf.dispatchFetch("http://localhost/cronwatch/")).status, 401);
  assert.equal((await mf.dispatchFetch("http://localhost/cronwatch/api/jobs", { headers: { authorization: "Bearer nope" } })).status, 401);
  const signIn = await mf.dispatchFetch("http://localhost/cronwatch/?token=tok", { redirect: "manual" });
  assert.equal(signIn.status, 303);
  assert.equal(signIn.headers.get("location"), "/cronwatch/");
  const cookie = signIn.headers.get("set-cookie")!.split(";")[0]!;
  const digest = createHash("sha256").update("cronwatch-cookie:tok").digest("hex");
  assert.equal(cookie, `cronwatch_token=${digest}`, "the same cookie as on Node, so a Node app and a Worker agree");
  const page = await mf.dispatchFetch("http://localhost/cronwatch/", { headers: { cookie } });
  assert.equal(page.status, 200);
  assert.match(page.headers.get("content-type")!, /text\/html/);
  const html = await page.text();
  assert.match(html, /hourly/);
  assert.match(html, /nightly/);

  // The check endpoint takes the cron secret as well as the token.
  const viaSecret = await mf.dispatchFetch("http://localhost/cronwatch/api/check", { method: "POST", headers: { authorization: "Bearer sec" } });
  assert.equal(viaSecret.status, 200);
  assert.equal(((await viaSecret.json()) as { ok: boolean }).ok, true);
});
