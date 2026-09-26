import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { test } from "node:test";
import { cronwatch } from "../src/index.js";
import { capture, clock, HOUR } from "./helpers.js";

function app(onError?: (error: unknown, where: string) => void) {
  const c = clock();
  const cw = cronwatch({ now: c.now, alerts: [capture()], cronSecret: null, onError });
  const routes = cw.routes({ token: "tok", basePath: "/cronwatch" });
  const send = (method: string, path: string, headers: Record<string, string> = {}, body?: string) =>
    routes.handler(new Request(`http://app.test${path}`, { method, headers, body }));
  const cookie = { cookie: `cronwatch_token=${createHash("sha256").update("cronwatch-cookie:tok").digest("hex")}` };
  const bearer = { authorization: "Bearer tok" };
  return { cw, c, routes, send, cookie, bearer };
}

test("cross-site writes are refused whatever the credentials", async () => {
  const { cw, send, cookie, bearer } = app();
  await cw.run("x", async () => {});
  const form = { "content-type": "application/x-www-form-urlencoded" };
  const foreign: Record<string, string>[] = [
    { origin: "https://evil.example" },
    { origin: "null" },
    { "sec-fetch-site": "cross-site" },
    { "sec-fetch-site": "same-site" },
    { origin: "http://app.test", "sec-fetch-site": "cross-site" },
  ];
  for (const headers of foreign) {
    assert.equal((await send("POST", "/cronwatch/jobs/x/silence", { ...cookie, ...form, ...headers }, "for=1h")).status, 403, JSON.stringify(headers));
    assert.equal((await send("POST", "/cronwatch/api/check", { ...bearer, ...headers })).status, 403, JSON.stringify(headers));
    assert.equal((await send("DELETE", "/cronwatch/api/jobs/x", { ...cookie, ...headers })).status, 403, JSON.stringify(headers));
  }
  assert.notEqual(await cw.jobSummary("x"), null);
  assert.equal((await cw.jobSummary("x"))!.silencedUntil, null);
});

test("same-origin forms and header-less API clients still write", async () => {
  const { cw, send, cookie, bearer } = app();
  await cw.run("x", async () => {});
  const sameOrigin = { origin: "http://app.test", "sec-fetch-site": "same-origin", referer: "http://app.test/cronwatch/jobs/x" };
  const check = await send("POST", "/cronwatch/check", { ...cookie, ...sameOrigin });
  assert.equal(check.status, 303, "the dashboard's Run check now button");
  const silence = await send("POST", "/cronwatch/jobs/x/silence", { ...cookie, ...sameOrigin, "content-type": "application/x-www-form-urlencoded" }, "for=4h");
  assert.equal(silence.status, 303);
  assert.equal(silence.headers.get("location"), "http://app.test/cronwatch/jobs/x");
  assert.equal((await send("POST", "/cronwatch/api/jobs/x/unsilence", bearer)).status, 200);
  assert.equal((await send("POST", "/cronwatch/api/check", { ...bearer, "sec-fetch-site": "none" })).status, 200);
});

test("GET /api/check runs only for a bearer; cookies must POST", async () => {
  const { send, cookie, bearer } = app();
  const viaCookie = await send("GET", "/cronwatch/api/check", cookie);
  assert.equal(viaCookie.status, 405);
  assert.equal(viaCookie.headers.get("allow"), "POST");
  assert.equal((await send("POST", "/cronwatch/api/check", cookie)).status, 200);
  assert.equal((await send("GET", "/cronwatch/api/check", bearer)).status, 200);
});

test("?token= is only accepted on an HTML GET", async () => {
  const { cw, send } = app();
  await cw.run("x", async () => {});
  assert.equal((await send("GET", "/cronwatch/api/jobs?token=tok")).status, 401);
  assert.equal((await send("GET", "/cronwatch/api/jobs/x?token=tok")).status, 401);
  assert.equal((await send("POST", "/cronwatch/api/check?token=tok")).status, 401);
  assert.equal((await send("POST", "/cronwatch/check?token=tok")).status, 401);
  assert.equal((await send("POST", "/cronwatch/jobs/x/forget?token=tok")).status, 401);
  assert.notEqual(await cw.jobSummary("x"), null);
  assert.equal((await send("GET", "/cronwatch/jobs/x?token=tok")).status, 303);
});

test("malformed cookies and paths are answered, not thrown", async () => {
  const { send, bearer } = app();
  assert.equal((await send("GET", "/cronwatch/", { cookie: "cronwatch_token=%E0%A4%A" })).status, 401);
  assert.equal((await send("GET", "/cronwatch/api/jobs", { cookie: "cronwatch_token=%" })).status, 401);
  assert.equal((await send("GET", "/cronwatch/jobs/%E0%A4%A", bearer)).status, 400);
  const api = await send("GET", "/cronwatch/api/jobs/%zz", bearer);
  assert.equal(api.status, 400);
  assert.equal((await api.json()).ok, false);
  assert.equal((await send("POST", "/cronwatch/api/jobs/%zz/silence", bearer)).status, 400);
});

test("?runs= is clamped to a whole number in range", async () => {
  const { cw, send, bearer } = app();
  for (let i = 0; i < 3; i++) await cw.run("r", async () => {});
  const count = async (runs: string) => (await (await send("GET", `/cronwatch/api/jobs/r?runs=${runs}`, bearer)).json()).runs.length;
  assert.equal(await count("0"), 1);
  assert.equal(await count("-5"), 1);
  assert.equal(await count("2.7"), 2);
  assert.equal(await count("abc"), 3);
  assert.equal(await count(""), 3);
  assert.equal(await count("1e9"), 3);
  assert.equal(await count("Infinity"), 3);
});

test("an unexpected error is a generic 500, reported through onError", async () => {
  const reported: [unknown, string][] = [];
  const { cw, send, bearer } = app((error, where) => reported.push([error, where]));
  cw.jobs = async () => { throw new Error("secret connection string"); };
  cw.jobsWithRuns = async () => { throw new Error("secret connection string"); };
  const api = await send("GET", "/cronwatch/api/jobs", bearer);
  assert.equal(api.status, 500);
  const body = await api.text();
  assert.doesNotMatch(body, /secret/);
  assert.deepEqual(JSON.parse(body), { ok: false, error: "Internal error" });
  const page = await send("GET", "/cronwatch/", bearer);
  assert.equal(page.status, 500);
  assert.match(page.headers.get("content-type")!, /text\/html/);
  assert.doesNotMatch(await page.text(), /secret/);
  assert.equal(reported.length, 2);
  assert.equal(reported[0]![1], "routes");
  assert.match((reported[0]![0] as Error).message, /secret connection string/);
});

test("a throwing onError still yields a 500", async () => {
  const { cw, send, bearer } = app(() => { throw new Error("logger down"); });
  cw.jobs = async () => { throw new Error("boom"); };
  assert.equal((await send("GET", "/cronwatch/api/jobs", bearer)).status, 500);
});

test("silence durations: strings are validated, numbers are milliseconds", async () => {
  const { cw, c, send, bearer } = app();
  await cw.run("s", async () => {});
  const json = { ...bearer, "content-type": "application/json" };
  const silence = (body: unknown) => send("POST", "/cronwatch/api/jobs/s/silence", json, JSON.stringify(body));

  for (const bad of ["forever", "2 hours", "", "-5", "1h then some"]) {
    const res = await silence({ for: bad });
    assert.equal(res.status, 400, bad);
    const body = await res.json();
    assert.equal(body.ok, false);
    assert.match(body.error, /silence duration/, bad);
  }
  assert.equal((await cw.jobSummary("s"))!.silencedUntil, null, "a bad duration silences nothing");

  const until = async (body: unknown) => (await (await silence(body)).json()).state.silencedUntil - c.now();
  assert.equal(await until({ for: 7_200_000 }), 7_200_000);
  assert.equal(await until({ for: "60000" }), 60_000);
  assert.equal(await until({ for: "90m" }), 90 * 60_000);
  assert.equal(await until({}), HOUR);
  const viaQuery = await send("POST", "/cronwatch/api/jobs/s/silence?for=forever", bearer);
  assert.equal(viaQuery.status, 400);
});

test("the silence form shows an error for a bad duration and 404s a missing job", async () => {
  const { cw, send, cookie } = app();
  await cw.run("s", async () => {});
  const form = { ...cookie, "content-type": "application/x-www-form-urlencoded" };
  const bad = await send("POST", "/cronwatch/jobs/s/silence", form, "for=forever");
  assert.equal(bad.status, 400);
  assert.match(bad.headers.get("content-type")!, /text\/html/);
  assert.match(await bad.text(), /silence duration &quot;forever&quot;/);
  assert.equal((await cw.jobSummary("s"))!.silencedUntil, null);
  assert.equal((await send("POST", "/cronwatch/jobs/ghost/silence", form, "for=1h")).status, 404);
  assert.equal((await send("POST", "/cronwatch/jobs/ghost/unsilence", form)).status, 404);
  assert.equal((await send("POST", "/cronwatch/jobs/s/explode", form)).status, 404);
});

test("pages carry a strict CSP and security headers, and need no script", async () => {
  const { cw, send, bearer } = app();
  await cw.run("h", async () => {});
  for (const path of ["/cronwatch/", "/cronwatch/jobs/h", "/cronwatch/nope"]) {
    const res = await send("GET", path, bearer);
    const csp = res.headers.get("content-security-policy")!;
    assert.match(csp, /default-src 'none'/);
    assert.match(csp, /frame-ancestors 'none'/);
    assert.match(csp, /form-action 'self'/);
    assert.doesNotMatch(csp, /script-src/);
    assert.equal(res.headers.get("x-frame-options"), "DENY");
    assert.equal(res.headers.get("x-content-type-options"), "nosniff");
    assert.equal(res.headers.get("referrer-policy"), "same-origin");
    assert.equal(res.headers.get("cache-control"), "no-store");
    const html = await res.text();
    assert.doesNotMatch(html, /<script/i);
    assert.doesNotMatch(html, /\son[a-z]+=/i, "no inline event handlers");
  }
  const page = await (await send("GET", "/cronwatch/jobs/h", bearer)).text();
  assert.match(page, /<details class="confirm"><summary>Forget<\/summary><form/, "forget confirms without script");
  const api = await send("GET", "/cronwatch/api/jobs", bearer);
  assert.equal(api.headers.get("x-content-type-options"), "nosniff");
  assert.equal(api.headers.get("cache-control"), "no-store");
});

test("markup in definitions, output and metrics stays escaped on every page", async () => {
  const { cw, send, bearer } = app();
  const job = cw.job("m", { schedule: "0 2 * * *", description: "<img src=x>", tags: ["<t>"], expect: "<e>" });
  await job.run(async (j) => { j.log("<o>"); j.metric("<k>", 1); });
  for (const path of ["/cronwatch/", "/cronwatch/jobs/m", "/cronwatch/jobs/%3Cx%3E"]) {
    const html = await (await send("GET", path, bearer)).text();
    assert.doesNotMatch(html, /<img|<t>|<e>|<o>|<k>|<x>/, path);
  }
});

/** No token in development: the routes as a dev server on this machine would serve them. */
function devRoutes() {
  const before = { NODE_ENV: process.env.NODE_ENV, CRONWATCH_TOKEN: process.env.CRONWATCH_TOKEN };
  process.env.NODE_ENV = "development";
  delete process.env.CRONWATCH_TOKEN;
  try {
    const cw = cronwatch({ alerts: [capture()], cronSecret: null });
    return cw.routes({ basePath: "/cronwatch" });
  } finally {
    for (const [k, v] of Object.entries(before)) {
      if (v === undefined) delete process.env[k]; else process.env[k] = v;
    }
  }
}

test("without a token, localhost means the URL, the Host header and every proxy header", async () => {
  const routes = devRoutes();
  const status = async (url: string, headers: Record<string, string> = {}) => (await routes.GET(new Request(url, { headers }))).status;
  const local = "http://localhost:3000/cronwatch/api/jobs";

  // What Next.js hands a route handler for a browser on this machine: its own
  // listen address as the URL, the Host sent, and the x-forwarded-* it fills in.
  const next = { host: "localhost:3000", "x-forwarded-host": "localhost:3000", "x-forwarded-for": "::ffff:127.0.0.1", "x-forwarded-port": "3000", "x-forwarded-proto": "http" };
  assert.equal(await status(local, next), 200);
  assert.equal(await status(local, { host: "127.0.0.1:3000", "x-forwarded-for": "::1" }), 200);
  assert.equal(await status(local, { host: "[::1]:3000", forwarded: 'for="[::1]:51234";host=localhost;proto=http' }), 200);
  assert.equal(await status(local), 200, "no Host header, as over HTTP/2: the URL's host is the authority");

  // Next.js builds request.url from its listen address, so each of these
  // arrives with a localhost URL.
  const refused: [string, Record<string, string>][] = [
    ["a rebinding page (Host names the attacker's domain)", { ...next, host: "evil.example", "x-forwarded-host": "evil.example" }],
    ["a LAN address", { ...next, host: "192.168.1.20:3000", "x-forwarded-host": "192.168.1.20:3000", "x-forwarded-for": "::ffff:192.168.1.20" }],
    ["a spoofed X-Forwarded-Host from another machine", { host: "192.168.1.20:3000", "x-forwarded-host": "localhost" }],
    ["a forged Host, but Next.js recorded the peer", { ...next, "x-forwarded-for": "::ffff:192.168.1.20" }],
    ["X-Forwarded-For through a proxy", { host: "localhost", "x-forwarded-for": "203.0.113.9, 127.0.0.1" }],
    ["X-Forwarded-Host naming a public host", { host: "localhost", "x-forwarded-host": "app.example" }],
    ["X-Real-IP", { host: "localhost", "x-real-ip": "203.0.113.9" }],
    ["Forwarded for=", { host: "localhost", forwarded: "for=203.0.113.9;proto=https" }],
    ["Forwarded host=", { host: "localhost", forwarded: 'for="[::1]";host=app.example' }],
    ["an obfuscated Forwarded for=", { host: "localhost", forwarded: "for=_hidden" }],
    ["localhost as a subdomain", { host: "localhost.evil.example" }],
  ];
  for (const [why, headers] of refused) assert.equal(await status(local, headers), 503, why);

  // Hono on Node takes the URL from an absolute-form request target, whatever Host says.
  assert.equal(await status(local, { host: "evil.example" }), 503, "an absolute-form target naming localhost");
  // Otherwise from Host, so a spoofed X-Forwarded-Host never reaches the URL.
  assert.equal(await status("http://evil.example/cronwatch/api/jobs", { host: "evil.example", "x-forwarded-host": "localhost" }), 503);
  assert.equal(await status("http://192.168.1.20:3000/cronwatch/api/jobs", { host: "localhost" }), 503, "an adapter trusting X-Forwarded-Host for the URL");
});
