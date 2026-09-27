import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { test } from "node:test";
import { cronwatch } from "../src/index.js";
import type { RoutesOptions } from "../src/index.js";
import { capture, clock, HOUR } from "./helpers.js";

/** An app that sees its requests on an internal URL, as it does behind a proxy. */
function app(options: RoutesOptions = {}, internal = "http://10.0.0.5:8080") {
  const c = clock();
  const cw = cronwatch({ now: c.now, alerts: [capture()], cronSecret: null });
  const routes = cw.routes({ token: "tok", basePath: "/cronwatch", ...options });
  const send = (method: string, path: string, headers: Record<string, string> = {}, body?: string) =>
    routes.handler(new Request(`${internal}${path}`, { method, headers, body }));
  const cookie = { cookie: `cronwatch_token=${createHash("sha256").update("cronwatch-cookie:tok").digest("hex")}` };
  const form = { "content-type": "application/x-www-form-urlencoded" };
  return { cw, c, send, cookie, form };
}

const silenced = async (cw: ReturnType<typeof app>["cw"]) => (await cw.jobSummary("x"))!.silencedUntil !== null;

test("by default the request URL's origin is the origin, as before", async () => {
  const { cw, send, cookie, form } = app();
  await cw.run("x", async () => {});
  const refused = await send("POST", "/cronwatch/jobs/x/silence", { ...cookie, ...form, origin: "https://app.example.com" }, "for=1h");
  assert.equal(refused.status, 403);
  assert.equal(await silenced(cw), false);
  const ok = await send("POST", "/cronwatch/jobs/x/silence", { ...cookie, ...form, origin: "http://10.0.0.5:8080" }, "for=1h");
  assert.equal(ok.status, 303);
  const signIn = await send("GET", "/cronwatch/?token=tok");
  assert.doesNotMatch(signIn.headers.get("set-cookie")!, /Secure/);
});

test("origin replaces the request URL's origin for writes, sign-in and redirects", async () => {
  const { cw, c, send, cookie, form } = app({ origin: "https://app.example.com/ignored/path" });
  await cw.run("x", async () => {});
  const internal = await send("POST", "/cronwatch/jobs/x/silence", { ...cookie, ...form, origin: "http://10.0.0.5:8080" }, "for=1h");
  assert.equal(internal.status, 403, "the internal origin is now foreign");
  assert.equal(await silenced(cw), false);

  const referer = "https://app.example.com/cronwatch/jobs/x";
  const ok = await send("POST", "/cronwatch/jobs/x/silence", { ...cookie, ...form, origin: "https://app.example.com", referer }, "for=2h");
  assert.equal(ok.status, 303);
  assert.equal(ok.headers.get("location"), referer, "the Referer on the public origin is followed back");
  assert.equal((await cw.jobSummary("x"))!.silencedUntil, c.now() + 2 * HOUR);

  const signIn = await send("GET", "/cronwatch/jobs/x?token=tok");
  assert.equal(signIn.status, 303);
  assert.equal(signIn.headers.get("location"), "/cronwatch/jobs/x");
  assert.match(signIn.headers.get("set-cookie")!, /; Secure$/, "the public origin is https, so the cookie is Secure");
});

test("origin takes precedence over trustProxy and forwarded headers", async () => {
  const { cw, send, cookie, form } = app({ origin: "https://app.example.com", trustProxy: true });
  await cw.run("x", async () => {});
  const forwarded = { "x-forwarded-proto": "https", "x-forwarded-host": "other.example" };
  assert.equal((await send("POST", "/cronwatch/check", { ...cookie, ...forwarded, origin: "https://other.example" })).status, 403);
  assert.equal((await send("POST", "/cronwatch/check", { ...cookie, ...forwarded, origin: "https://app.example.com" })).status, 303);
});

test("an origin that is not an http or https URL fails when the routes are made", () => {
  const cw = cronwatch({ alerts: [capture()], cronSecret: null });
  assert.throws(() => cw.routes({ token: "tok", origin: "app.example.com" }), /origin must be an absolute URL/);
  assert.throws(() => cw.routes({ token: "tok", origin: "ftp://app.example.com" }), /origin must be http or https/);
  assert.doesNotThrow(() => cw.routes({ token: "tok", origin: "" }));
});

test("trustProxy takes the origin from the first X-Forwarded-Proto and X-Forwarded-Host", async () => {
  const { cw, send, cookie, form } = app({ trustProxy: true });
  await cw.run("x", async () => {});
  const forwarded = { "x-forwarded-proto": "https, http", "x-forwarded-host": "app.example.com, 10.0.0.5:8080" };
  assert.equal((await send("POST", "/cronwatch/jobs/x/silence", { ...cookie, ...form, ...forwarded, origin: "http://10.0.0.5:8080" }, "for=1h")).status, 403);
  const ok = await send("POST", "/cronwatch/jobs/x/silence", { ...cookie, ...form, ...forwarded, origin: "https://app.example.com" }, "for=1h");
  assert.equal(ok.status, 303);
  const signIn = await send("GET", "/cronwatch/?token=tok", forwarded);
  assert.match(signIn.headers.get("set-cookie")!, /; Secure$/);

  // Only the scheme forwarded: the host stays the request's.
  const protoOnly = { "x-forwarded-proto": "https" };
  assert.equal((await send("POST", "/cronwatch/check", { ...cookie, ...protoOnly, origin: "https://10.0.0.5:8080" })).status, 303);
  // Neither forwarded: the request URL's origin, as without trustProxy.
  assert.equal((await send("POST", "/cronwatch/check", { ...cookie, origin: "http://10.0.0.5:8080" })).status, 303);
});

test("trustProxy ignores forwarded values that are not a scheme and a bare host", async () => {
  const { cw, send, cookie } = app({ trustProxy: true });
  await cw.run("x", async () => {});
  const cases: [Record<string, string>, string][] = [
    [{ "x-forwarded-proto": "javascript", "x-forwarded-host": "evil.example" }, "javascript://evil.example"],
    [{ "x-forwarded-proto": "https", "x-forwarded-host": "evil.example/path" }, "https://evil.example"],
    [{ "x-forwarded-proto": "https", "x-forwarded-host": "user@evil.example" }, "https://evil.example"],
  ];
  for (const [headers, origin] of cases) {
    assert.equal((await send("POST", "/cronwatch/check", { ...cookie, ...headers, origin })).status, 403, JSON.stringify(headers));
    assert.equal((await send("POST", "/cronwatch/check", { ...cookie, ...headers, origin: "http://10.0.0.5:8080" })).status, 303, JSON.stringify(headers));
  }
});

test("without trustProxy a spoofed X-Forwarded-Host or Proto changes nothing", async () => {
  const { cw, send, cookie, form } = app({}, "http://app.test");
  await cw.run("x", async () => {});
  const spoofed = { "x-forwarded-host": "evil.example", "x-forwarded-proto": "https" };
  const foreign = await send("POST", "/cronwatch/jobs/x/silence", { ...cookie, ...form, ...spoofed, origin: "https://evil.example" }, "for=1h");
  assert.equal(foreign.status, 403);
  assert.equal(await silenced(cw), false);
  const back = await send("POST", "/cronwatch/check", { ...cookie, ...spoofed, origin: "http://app.test", referer: "https://evil.example/cronwatch/jobs/x" });
  assert.equal(back.status, 303);
  assert.equal(back.headers.get("location"), "/cronwatch/", "a Referer on the spoofed origin is not followed");
  const signIn = await send("GET", "/cronwatch/?token=tok", spoofed);
  assert.doesNotMatch(signIn.headers.get("set-cookie")!, /Secure/);
});

test("the development sign-in line uses the public origin", async () => {
  const saved = { NODE_ENV: process.env.NODE_ENV, CRONWATCH_TOKEN: process.env.CRONWATCH_TOKEN };
  process.env.NODE_ENV = "development";
  delete process.env.CRONWATCH_TOKEN;
  const lines: string[] = [];
  const info = console.info;
  console.info = (...parts: unknown[]) => { lines.push(parts.map(String).join(" ")); };
  try {
    const cw = cronwatch({ alerts: [capture()], cronSecret: null });
    await cw.routes({ origin: "https://app.example.com" }).handler(new Request("http://10.0.0.5:8080/cronwatch/"));
    await cw.routes({ trustProxy: true }).handler(new Request("http://10.0.0.5:8080/cronwatch/", {
      headers: { "x-forwarded-proto": "https", "x-forwarded-host": "proxied.example" },
    }));
    await cw.routes({}).handler(new Request("http://10.0.0.5:8080/cronwatch/", {
      headers: { "x-forwarded-proto": "https", "x-forwarded-host": "proxied.example" },
    }));
  } finally {
    console.info = info;
    for (const [k, v] of Object.entries(saved)) {
      if (v === undefined) delete process.env[k]; else process.env[k] = v;
    }
  }
  assert.equal(lines.length, 3);
  assert.match(lines[0]!, /Sign in: https:\/\/app\.example\.com\/cronwatch\/\?token=/);
  assert.match(lines[1]!, /Sign in: https:\/\/proxied\.example\/cronwatch\/\?token=/);
  assert.match(lines[2]!, /Sign in: http:\/\/10\.0\.0\.5:8080\/cronwatch\/\?token=/);
});
