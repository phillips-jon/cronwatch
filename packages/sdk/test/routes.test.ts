import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { test } from "node:test";
import { cronwatch } from "../src/index.js";
import { escapeName } from "../src/routes/escape.js";
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
  const digest = createHash("sha256").update("cronwatch-cookie:tok").digest("hex");
  assert.equal(cookie.split(";")[0], `cronwatch_token=${digest}`, "a digest, not the token");
  assert.match(cookie, /; Path=\/cronwatch; HttpOnly; SameSite=Lax/);
  const page = await get("/cronwatch/", { headers: { cookie: `other=1; cronwatch_token=${digest}` } });
  assert.equal(page.status, 200);
  assert.equal((await get("/cronwatch/", { headers: { cookie: "cronwatch_token=tok" } })).status, 401, "the raw token is not a cookie");
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
  assert.match(dash, /<p class="headline">2 jobs, <b>1 needing attention<\/b>\.<\/p>/);
  assert.match(dash, /<div class="bad"><dt><i class="sq bad" aria-hidden="true"><\/i>failing<\/dt><dd>1<\/dd><\/div>/, "counts by health");
  assert.match(dash, /<section class="sec" aria-label="Last 24 hours">[\s\S]*<figure class="timeline day">/);
  assert.match(dash, /<table class="board">/);
  assert.match(dash, /<form class="inline" method="post" action="\/cronwatch\/check"><button class="primary" type="submit">Run check now<\/button><\/form>/);

  const page = await get("/cronwatch/jobs/broken", { headers: auth });
  assert.equal(page.status, 200);
  const html = await page.text();
  assert.match(html, /kaboom &lt;script&gt;/, "error text is escaped");
  assert.doesNotMatch(html, /<script>/);
  assert.match(html, /<h1 class="jobname">broken<\/h1>/);
  assert.match(html, /<figure class="timeline week">/);
  assert.match(html, /<details class="out error" open><summary>error<\/summary><pre>Error: kaboom &lt;script&gt;/);

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

test("escapeName escapes, then allows a break after each run of separators but not at the end", () => {
  assert.equal(escapeName("a/b::c<d>-"), "a/<wbr>b::<wbr>c&lt;d&gt;-");
  assert.equal(escapeName("plain"), "plain");
});

test("a long name may break after its separators wherever it is text, and nowhere else", async () => {
  const { cw, get, auth } = app();
  const name = "wp:store_sync.inventory--eu";
  await cw.run(name, async () => {});
  const shown = "wp:<wbr>store_<wbr>sync.<wbr>inventory--<wbr>eu";
  const href = `/cronwatch/jobs/${encodeURIComponent(name)}`;

  const dash = await (await get("/cronwatch", { headers: auth })).text();
  assert.ok(dash.includes(`<a class="name" href="${href}">${shown}</a><span class="sched">`), "the lane");
  assert.ok(dash.includes(`<td class="job"><a class="name" href="${href}">${shown}</a></td>`), "the board");
  assert.ok(dash.includes(`<li>wp:store_sync.inventory--eu (`), "the lane in words, unbroken");

  const page = await (await get(href, { headers: auth })).text();
  assert.ok(page.includes(`<span class="crumb">${shown}</span>`), "the breadcrumb");
  assert.ok(page.includes(`<h1 class="jobname">${shown}</h1>`), "the heading");
  assert.ok(page.includes(`<title>wp:store_sync.inventory--eu: CronWatch</title>`), "the title, unbroken");
  assert.ok(page.includes(`<title>wp:store_sync.inventory--eu, `), "the marks' titles, unbroken");
  assert.equal(page.match(/<wbr>/g)?.length, 8, "only in the crumb and the heading");
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

function unconfigured(token?: string | null, host = "localhost") {
  const cw = cronwatch({ alerts: [capture()], cronSecret: null });
  const routes = cw.routes(token === undefined ? {} : { token });
  return (path: string) => routes.GET(new Request(`http://${host}${path}`));
}

/** Captures console.info while `fn` runs. */
async function logged<T>(fn: () => Promise<T>): Promise<{ lines: string[]; result: T }> {
  const lines: string[] = [];
  const info = console.info;
  console.info = (...parts: unknown[]) => { lines.push(parts.map(String).join(" ")); };
  try {
    return { lines, result: await fn() };
  } finally {
    console.info = info;
  }
}

test("without a token outside development the routes are locked", async () => {
  for (const env of [undefined, "production", "staging", ""]) {
    await withEnv({ NODE_ENV: env, CRONWATCH_TOKEN: undefined }, async () => {
      const get = unconfigured();
      assert.equal((await get("/cronwatch/api/jobs")).status, 503, `NODE_ENV=${env}`);
      assert.equal((await get("/cronwatch")).status, 503, `NODE_ENV=${env}`);
    });
  }
});

test("without a token in development, a made-up token is printed once and required from everyone", async () => {
  for (const env of ["development", "test"]) {
    await withEnv({ NODE_ENV: env, CRONWATCH_TOKEN: undefined }, async () => {
      const cw = cronwatch({ alerts: [capture()], cronSecret: null });
      const routes = cw.routes({ basePath: "/cronwatch/" });
      const { lines } = await logged(async () => {
        // Every request is refused without the token, whatever it claims about where it came from.
        for (const [url, headers] of [
          ["http://localhost:3000/cronwatch/api/jobs", {}],
          ["http://localhost:3000/cronwatch/api/jobs", { host: "localhost:3000", "x-forwarded-for": "127.0.0.1" }],
          ["http://127.0.0.1:3000/cronwatch/", {}],
          ["http://192.168.1.20:3000/cronwatch/api/jobs", {}],
        ] as [string, Record<string, string>][]) {
          assert.equal((await routes.GET(new Request(url, { headers }))).status, 401, `${url} NODE_ENV=${env}`);
        }
      });
      assert.equal(lines.length, 1, "announced once, on the first request");
      const match = /^\[cronwatch\] CRONWATCH_TOKEN is not set, so this development server made a token for the dashboard\. Sign in: http:\/\/localhost:3000\/cronwatch\/\?token=([A-Za-z0-9_-]{43})$/.exec(lines[0]!);
      assert.ok(match, lines[0]);
      const token = match[1]!;

      const page = await routes.GET(new Request("http://localhost:3000/cronwatch/"));
      assert.equal(page.status, 401);
      assert.match(await page.text(), /sign-in link is in the server log/);
      const api = await routes.GET(new Request("http://localhost:3000/cronwatch/api/jobs"));
      assert.match((await api.json()).error, /in the server log/);

      const signIn = await routes.GET(new Request(`http://localhost:3000/cronwatch/?token=${token}`));
      assert.equal(signIn.status, 303);
      assert.equal(signIn.headers.get("location"), "/cronwatch/");
      const cookie = signIn.headers.get("set-cookie")!.split(";")[0]!;
      assert.equal((await routes.GET(new Request("http://localhost:3000/cronwatch/", { headers: { cookie } }))).status, 200);
      assert.equal((await routes.GET(new Request("http://localhost:3000/cronwatch/api/jobs", { headers: { authorization: `Bearer ${token}` } }))).status, 200);

      const other = cronwatch({ alerts: [capture()], cronSecret: null }).routes({ basePath: "/" });
      const { lines: second } = await logged(async () => other.GET(new Request("https://dev.example:8443/api/jobs")));
      assert.match(second[0]!, /Sign in: https:\/\/dev\.example:8443\/\?token=[A-Za-z0-9_-]{43}$/, "the origin as requested, and a root mount");
      assert.notEqual(second[0]!.slice(-43), token, "each routes instance makes its own");
    });
  }
});

test("an empty token counts as unset; null opts out explicitly", async () => {
  await withEnv({ NODE_ENV: "production", CRONWATCH_TOKEN: "" }, async () => {
    assert.equal((await unconfigured()("/cronwatch/api/jobs")).status, 503);
    assert.equal((await unconfigured("")("/cronwatch/api/jobs")).status, 503);
    assert.equal((await unconfigured(null, "app.test")("/cronwatch/api/jobs")).status, 200, "token: null serves open");
  });
  await withEnv({ NODE_ENV: "development", CRONWATCH_TOKEN: undefined }, async () => {
    const { lines, result } = await logged(async () => unconfigured(null, "app.test")("/cronwatch/api/jobs"));
    assert.equal(result.status, 200, "token: null serves open in development too");
    assert.deepEqual(lines, [], "and makes no token");
  });
  await withEnv({ NODE_ENV: "development", CRONWATCH_TOKEN: "envtok" }, async () => {
    const { lines, result } = await logged(async () => unconfigured()("/cronwatch/api/jobs"));
    assert.equal(result.status, 401, "a configured token is used in development");
    assert.deepEqual(lines, []);
  });
  await withEnv({ NODE_ENV: "production", CRONWATCH_TOKEN: "envtok" }, async () => {
    const cw = cronwatch({ alerts: [capture()], cronSecret: null });
    const routes = cw.routes({ token: "" });
    assert.equal((await routes.GET(new Request("http://app.test/cronwatch/api/jobs"))).status, 401);
    assert.equal((await routes.GET(new Request("http://app.test/cronwatch/api/jobs", { headers: { authorization: "Bearer envtok" } }))).status, 200);
  });
});
