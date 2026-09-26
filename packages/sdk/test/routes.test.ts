import assert from "node:assert/strict";
import { test } from "node:test";
import { cronwatch } from "../src/index.js";
import { capture, clock } from "./helpers.js";

function app(token: string | null = "tok") {
  const c = clock();
  const cw = cronwatch({ now: c.now, alerts: [capture()], cronSecret: null });
  const routes = cw.routes({ token, basePath: "/cronwatch" });
  const get = (path: string, init: RequestInit = {}) => routes.GET(new Request(`http://app.test${path}`, init));
  const auth = { authorization: "Bearer tok" };
  return { cw, c, routes, get, auth };
}

test("everything needs the token", async () => {
  const { get } = app();
  assert.equal((await get("/cronwatch")).status, 401);
  assert.equal((await get("/cronwatch/api/jobs")).status, 401);
  assert.equal((await get("/cronwatch/api/jobs", { headers: { authorization: "Bearer wrong" } })).status, 401);
  assert.equal((await get("/cronwatch/api/jobs", { headers: { authorization: "Bearer tok" } })).status, 200);
});

test("the check endpoint also accepts the cron secret, nothing else does", async () => {
  const c = clock();
  const cw = cronwatch({ now: c.now, alerts: [capture()], cronSecret: "cron-s3cret" });
  const routes = cw.routes({ token: "tok", basePath: "/cronwatch" });
  const withCron = { headers: { authorization: "Bearer cron-s3cret" } };
  assert.equal((await routes.GET(new Request("http://app.test/cronwatch/api/check", withCron))).status, 200);
  assert.equal((await routes.GET(new Request("http://app.test/cronwatch/api/jobs", withCron))).status, 401);
  assert.equal((await routes.GET(new Request("http://app.test/cronwatch/api/check?token=cron-s3cret"))).status, 401, "only as a bearer header");
});

test("?token= sets a cookie and redirects to a clean URL", async () => {
  const { get } = app();
  const res = await get("/cronwatch/?token=tok");
  assert.equal(res.status, 303);
  assert.equal(res.headers.get("location"), "/cronwatch/");
  const cookie = res.headers.get("set-cookie")!;
  assert.match(cookie, /^cronwatch_token=tok; Path=\/cronwatch; HttpOnly; SameSite=Lax/);
  const page = await get("/cronwatch/", { headers: { cookie: "other=1; cronwatch_token=tok" } });
  assert.equal(page.status, 200);
  assert.match(page.headers.get("content-type")!, /text\/html/);
});

test("dashboard and job pages render, JSON API answers", async () => {
  const { cw, get, auth, c } = app();
  const job = cw.job("nightly-report", { schedule: "0 2 * * *", description: "Builds the PDF" });
  await job.run(async (j) => { j.log("built"); c.advance(2000); });
  await assert.rejects(cw.run("broken", async () => { throw new Error("kaboom <script>"); }));

  const dash = await (await get("/cronwatch", { headers: auth })).text();
  assert.match(dash, /nightly-report/);
  assert.match(dash, /Builds the PDF/);
  assert.match(dash, /healthy/);
  assert.match(dash, /failing/);

  const page = await get("/cronwatch/jobs/broken", { headers: auth });
  assert.equal(page.status, 200);
  const html = await page.text();
  assert.match(html, /kaboom &lt;script&gt;/, "error text is escaped");
  assert.doesNotMatch(html, /<script>/);

  const list = await (await get("/cronwatch/api/jobs", { headers: auth })).json();
  assert.equal(list.jobs.length, 2);
  const one = await (await get("/cronwatch/api/jobs/nightly-report?runs=5", { headers: auth })).json();
  assert.equal(one.job.health, "healthy");
  assert.equal(one.runs.length, 1);
  assert.equal(one.runs[0].output, "built");

  assert.equal((await get("/cronwatch/api/jobs/missing", { headers: auth })).status, 404);
  assert.equal((await get("/cronwatch/jobs/missing", { headers: auth })).status, 404);
  assert.equal((await get("/cronwatch/nope", { headers: auth })).status, 404);
});

test("check, silence, unsilence and forget over the API", async () => {
  const { cw, routes, auth } = app();
  await cw.run("s", async () => {});
  const post = (path: string, body?: unknown) => routes.POST(new Request(`http://app.test${path}`, {
    method: "POST", headers: { ...auth, "content-type": "application/json" }, body: body === undefined ? null : JSON.stringify(body),
  }));
  const check = await (await post("/cronwatch/api/check")).json();
  assert.equal(check.ok, true);
  assert.equal(check.jobs.length, 1);
  const silenced = await (await post("/cronwatch/api/jobs/s/silence", { for: "2h" })).json();
  assert.ok(silenced.state.silencedUntil > 0);
  assert.equal((await cw.jobSummary("s"))!.health, "silenced");
  const un = await (await post("/cronwatch/api/jobs/s/unsilence")).json();
  assert.equal(un.state.silencedUntil, null);
  assert.equal((await post("/cronwatch/api/jobs/nope/silence", { for: "1h" })).status, 404);
  const del = await routes.DELETE(new Request("http://app.test/cronwatch/api/jobs/s", { method: "DELETE", headers: auth }));
  assert.equal(del.status, 200);
  assert.equal(await cw.jobSummary("s"), null);
});

test("dashboard forms post and redirect back", async () => {
  const { cw, routes, auth } = app();
  await cw.run("f", async () => {});
  const form = await routes.POST(new Request("http://app.test/cronwatch/jobs/f/silence", {
    method: "POST", headers: { ...auth, "content-type": "application/x-www-form-urlencoded", referer: "http://app.test/cronwatch/jobs/f" },
    body: "for=4h",
  }));
  assert.equal(form.status, 303);
  assert.equal(form.headers.get("location"), "http://app.test/cronwatch/jobs/f");
  assert.equal((await cw.jobSummary("f"))!.health, "silenced");
  const elsewhere = await routes.POST(new Request("http://app.test/cronwatch/jobs/f/unsilence", {
    method: "POST", headers: { ...auth, referer: "https://evil.example/phish" },
  }));
  assert.equal(elsewhere.headers.get("location"), "/cronwatch/", "a foreign referer is not followed");
});

async function withEnv<T>(env: Record<string, string | undefined>, fn: () => Promise<T>): Promise<T> {
  const before: Record<string, string | undefined> = {};
  for (const [k, v] of Object.entries(env)) {
    before[k] = process.env[k];
    if (v === undefined) delete process.env[k]; else process.env[k] = v;
  }
  try {
    return await fn();
  } finally {
    for (const [k, v] of Object.entries(before)) {
      if (v === undefined) delete process.env[k]; else process.env[k] = v;
    }
  }
}

function unconfigured(token?: string | null) {
  const cw = cronwatch({ alerts: [capture()], cronSecret: null });
  const routes = cw.routes(token === undefined ? {} : { token });
  return (path: string) => routes.GET(new Request(`http://app.test${path}`));
}

test("without a token: open only in development and test, locked otherwise", async () => {
  for (const env of [undefined, "production", "staging", ""]) {
    await withEnv({ NODE_ENV: env, CRONWATCH_TOKEN: undefined }, async () => {
      const get = unconfigured();
      assert.equal((await get("/cronwatch/api/jobs")).status, 503, `NODE_ENV=${env}`);
      assert.equal((await get("/cronwatch")).status, 503, `NODE_ENV=${env}`);
    });
  }
  for (const env of ["development", "test"]) {
    await withEnv({ NODE_ENV: env, CRONWATCH_TOKEN: undefined }, async () => {
      assert.equal((await unconfigured()("/cronwatch/api/jobs")).status, 200, `NODE_ENV=${env}`);
    });
  }
});

test("an empty token counts as unset; null opts out explicitly", async () => {
  await withEnv({ NODE_ENV: "production", CRONWATCH_TOKEN: "" }, async () => {
    assert.equal((await unconfigured()("/cronwatch/api/jobs")).status, 503);
    assert.equal((await unconfigured("")("/cronwatch/api/jobs")).status, 503);
    assert.equal((await unconfigured(null)("/cronwatch/api/jobs")).status, 200, "token: null serves open");
  });
  await withEnv({ NODE_ENV: "production", CRONWATCH_TOKEN: "envtok" }, async () => {
    const cw = cronwatch({ alerts: [capture()], cronSecret: null });
    const routes = cw.routes({ token: "" });
    assert.equal((await routes.GET(new Request("http://app.test/cronwatch/api/jobs"))).status, 401);
    assert.equal((await routes.GET(new Request("http://app.test/cronwatch/api/jobs", { headers: { authorization: "Bearer envtok" } }))).status, 200);
  });
});
