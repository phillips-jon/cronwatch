import assert from "node:assert/strict";
import { createServer, type IncomingMessage, type RequestListener, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { test } from "node:test";
import express from "express";
import Koa from "koa";
import { cronwatch } from "../src/index.js";
import { toKoaMiddleware, toNodeHandler } from "../src/node.js";
import { capture, clock, HOUR } from "./helpers.js";

/** Starts a server on a free port, runs `fn` against its base URL, then closes it. */
async function serving(listener: RequestListener, fn: (base: string) => Promise<void>): Promise<void> {
  const server: Server = createServer(listener);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as AddressInfo;
  try {
    await fn(`http://127.0.0.1:${port}`);
  } finally {
    server.closeAllConnections();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
}

function setup() {
  const c = clock();
  const cw = cronwatch({ now: c.now, alerts: [capture()], cronSecret: null });
  const routes = cw.routes({ token: "tok", basePath: "/cronwatch" });
  return { cw, c, routes };
}

/**
 * The dashboard's round trip through a server at `base`: sign in with
 * ?token=, read the dashboard with the cookie, silence from the form, read
 * and write the JSON API, and run the check.
 */
async function dashboardRoundTrip(base: string, cw: ReturnType<typeof setup>["cw"], now: () => number): Promise<void> {
  await cw.run("x", async () => {});
  const origin = new URL(base).origin;

  const signIn = await fetch(`${base}/cronwatch/?token=tok`, { redirect: "manual" });
  assert.equal(signIn.status, 303);
  assert.equal(signIn.headers.get("location"), "/cronwatch/");
  const setCookie = signIn.headers.getSetCookie();
  assert.equal(setCookie.length, 1);
  assert.match(setCookie[0]!, /^cronwatch_token=[0-9a-f]{64}; Path=\/cronwatch; HttpOnly; SameSite=Lax/);
  const cookie = setCookie[0]!.split(";")[0]!;

  const page = await fetch(`${base}/cronwatch/`, { headers: { cookie } });
  assert.equal(page.status, 200);
  assert.match(page.headers.get("content-type")!, /text\/html/);
  assert.match(page.headers.get("content-security-policy")!, /default-src 'none'/);
  assert.match(await page.text(), /x/);

  const referer = `${origin}/cronwatch/jobs/x`;
  const silence = await fetch(`${base}/cronwatch/jobs/x/silence`, {
    method: "POST",
    redirect: "manual",
    headers: { cookie, origin, referer, "content-type": "application/x-www-form-urlencoded" },
    body: "for=4h",
  });
  assert.equal(silence.status, 303);
  assert.equal(silence.headers.get("location"), referer);
  assert.equal((await cw.jobSummary("x"))!.silencedUntil, now() + 4 * HOUR);

  const jobs = await fetch(`${base}/cronwatch/api/jobs`, { headers: { authorization: "Bearer tok" } });
  assert.equal(jobs.status, 200);
  const body = (await jobs.json()) as { ok: boolean; jobs: { name: string }[] };
  assert.deepEqual(body.jobs.map((j) => j.name), ["x"]);

  const json = await fetch(`${base}/cronwatch/api/jobs/x/silence`, {
    method: "POST",
    headers: { authorization: "Bearer tok", "content-type": "application/json" },
    body: JSON.stringify({ for: "2h" }),
  });
  assert.equal(json.status, 200);
  assert.equal((await cw.jobSummary("x"))!.silencedUntil, now() + 2 * HOUR);

  const check = await fetch(`${base}/cronwatch/api/check`, { method: "POST", headers: { authorization: "Bearer tok" } });
  assert.equal(check.status, 200);
  assert.equal(((await check.json()) as { ok: boolean }).ok, true);

  const foreign = await fetch(`${base}/cronwatch/check`, { method: "POST", redirect: "manual", headers: { cookie, origin: "https://evil.example" } });
  assert.equal(foreign.status, 403);
}

test("a plain node:http server", async () => {
  const { cw, c, routes } = setup();
  await serving(toNodeHandler(routes.handler), (base) => dashboardRoundTrip(base, cw, c.now));
});

test("Express 5, mounted with app.use and a path, after express.json and express.urlencoded", async () => {
  const { cw, c, routes } = setup();
  const app = express();
  app.use(express.json());
  app.use(express.urlencoded({ extended: false }));
  app.use("/cronwatch", toNodeHandler(routes.handler));
  app.get("/hello", (_req, res) => { res.send("hello"); });
  await serving(app, async (base) => {
    await dashboardRoundTrip(base, cw, c.now);
    assert.equal(await (await fetch(`${base}/hello`)).text(), "hello");
  });
});

test("Express 5 with basePath passes other paths to next()", async () => {
  const { cw, c, routes } = setup();
  const app = express();
  app.use(toNodeHandler(routes.handler, { basePath: "/cronwatch" }));
  app.use(express.urlencoded({ extended: false }));
  app.get("/hello", (_req, res) => { res.send("hello"); });
  app.get("/cronwatchers", (_req, res) => { res.send("not the dashboard"); });
  await serving(app, async (base) => {
    await dashboardRoundTrip(base, cw, c.now);
    assert.equal(await (await fetch(`${base}/hello`)).text(), "hello");
    assert.equal(await (await fetch(`${base}/cronwatchers`)).text(), "not the dashboard");
    // /cronwatch itself, without the slash, is the dashboard too.
    assert.equal((await fetch(`${base}/cronwatch`, { headers: { authorization: "Bearer tok" } })).status, 200);
  });
});

test("Express 5 hands an error from the fetch handler to next(error)", async () => {
  const app = express();
  app.use("/boom", toNodeHandler(async () => { throw new Error("boom"); }));
  app.use((error: Error, _req: express.Request, res: express.Response, _next: express.NextFunction) => {
    res.status(418).send(`caught ${error.message}`);
  });
  await serving(app, async (base) => {
    const res = await fetch(`${base}/boom`);
    assert.equal(res.status, 418);
    assert.equal(await res.text(), "caught boom");
  });
});

test("Koa 3 middleware, with other paths passed on", async () => {
  const { cw, c, routes } = setup();
  const app = new Koa();
  app.use(toKoaMiddleware(routes.handler, { basePath: "/cronwatch" }));
  app.use((ctx) => { ctx.body = "koa"; });
  await serving(app.callback(), async (base) => {
    await dashboardRoundTrip(base, cw, c.now);
    assert.equal(await (await fetch(`${base}/elsewhere`)).text(), "koa");
  });
});

test("Koa 3 with a body parser before it uses ctx.request.rawBody", async () => {
  const { cw, c, routes } = setup();
  const app = new Koa();
  app.use(async (ctx, next) => {
    // What koa-bodyparser leaves behind: the stream read, the text kept.
    const chunks: Buffer[] = [];
    for await (const chunk of ctx.req) chunks.push(chunk as Buffer);
    const text = Buffer.concat(chunks).toString("utf8");
    (ctx.request as unknown as { rawBody: string }).rawBody = text;
    await next();
  });
  app.use(toKoaMiddleware(routes.handler));
  await serving(app.callback(), (base) => dashboardRoundTrip(base, cw, c.now));
});

test("a Firebase-style request whose stream is consumed and whose body is in req.rawBody", async () => {
  const { cw, c, routes } = setup();
  const handler = toNodeHandler(routes.handler);
  // The functions framework reads the body before the function runs, keeps
  // the bytes as req.rawBody and a parsed copy as req.body.
  const firebase: RequestListener = async (req, res) => {
    const chunks: Buffer[] = [];
    for await (const chunk of req) chunks.push(chunk as Buffer);
    const raw = Buffer.concat(chunks);
    const r = req as IncomingMessage & { rawBody: Buffer; body: unknown };
    r.rawBody = raw;
    r.body = { parsed: "and ignored, because rawBody wins" };
    await handler(req, res);
  };
  await serving(firebase, (base) => dashboardRoundTrip(base, cw, c.now));
});

test("a parsed body with no rawBody is encoded again for its content type", async () => {
  const seen: { method: string; type: string | null; body: string; length: string | null }[] = [];
  const echo = toNodeHandler(async (request) => {
    seen.push({ method: request.method, type: request.headers.get("content-type"), body: await request.text(), length: request.headers.get("content-length") });
    return new Response("ok");
  });
  const parsedAs = (body: unknown): RequestListener => async (req, res) => {
    for await (const _ of req) { /* drain, as a parser would */ }
    (req as IncomingMessage & { body: unknown }).body = body;
    await echo(req, res);
  };
  await serving(parsedAs({ for: "3h", tag: ["a", "b"] }), async (base) => {
    await fetch(base, { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: "for=3h&tag=a&tag=b" });
  });
  await serving(parsedAs({ for: "3h" }), async (base) => {
    await fetch(base, { method: "POST", headers: { "content-type": "application/json; charset=utf-8" }, body: '{ "for" : "3h" }' });
  });
  await serving(parsedAs({ file: "x" }), async (base) => {
    await fetch(base, { method: "POST", headers: { "content-type": "multipart/form-data; boundary=b" }, body: "--b--" });
  });
  assert.deepEqual(seen, [
    { method: "POST", type: "application/x-www-form-urlencoded", body: "for=3h&tag=a&tag=b", length: null },
    { method: "POST", type: "application/json; charset=utf-8", body: '{"for":"3h"}', length: null },
    { method: "POST", type: "multipart/form-data; boundary=b", body: "", length: null },
  ]);
});

test("the Request carries the method, headers, URL and a streamed body", async () => {
  let seen: Request | null = null;
  let text = "";
  const handler = toNodeHandler(async (request) => {
    seen = request;
    text = await request.text();
    return new Response("ok");
  });
  await serving(handler, async (base) => {
    await fetch(`${base}/a/b?c=1&d=2`, { method: "PUT", headers: { "x-thing": "one", "content-type": "text/plain" }, body: "hello body" });
  });
  const request = seen as Request | null;
  assert.ok(request);
  assert.equal(request.method, "PUT");
  assert.match(request.url, /^http:\/\/127\.0\.0\.1:\d+\/a\/b\?c=1&d=2$/);
  assert.equal(request.headers.get("x-thing"), "one");
  assert.equal(text, "hello body");
});

test("the URL follows X-Forwarded-Proto and X-Forwarded-Host only with trustProxy", async () => {
  const urls: string[] = [];
  const record = async (request: Request) => { urls.push(request.url); return new Response("ok"); };
  const forwarded = { "x-forwarded-proto": "https, http", "x-forwarded-host": "app.example.com, internal" };
  await serving(toNodeHandler(record), async (base) => {
    await fetch(`${base}/cronwatch/`, { headers: forwarded });
  });
  await serving(toNodeHandler(record, { trustProxy: true }), async (base) => {
    await fetch(`${base}/cronwatch/`, { headers: forwarded });
    await fetch(`${base}/cronwatch/`, { headers: { "x-forwarded-host": "bad/host" } });
  });
  assert.match(urls[0]!, /^http:\/\/127\.0\.0\.1:\d+\/cronwatch\/$/);
  assert.equal(urls[1], "https://app.example.com/cronwatch/");
  assert.match(urls[2]!, /^http:\/\/127\.0\.0\.1:\d+\/cronwatch\/$/, "a forwarded host that is not a host is ignored");
});

test("behind a TLS proxy, trustProxy lets same-origin dashboard forms through", async () => {
  const { cw, routes } = setup();
  await cw.run("x", async () => {});
  const headers = { authorization: "Bearer tok", "x-forwarded-proto": "https", "x-forwarded-host": "app.example.com", origin: "https://app.example.com" };
  await serving(toNodeHandler(routes.handler), async (base) => {
    assert.equal((await fetch(`${base}/cronwatch/check`, { method: "POST", redirect: "manual", headers })).status, 403);
  });
  await serving(toNodeHandler(routes.handler, { trustProxy: true }), async (base) => {
    assert.equal((await fetch(`${base}/cronwatch/check`, { method: "POST", redirect: "manual", headers })).status, 303);
    const signIn = await fetch(`${base}/cronwatch/?token=tok`, { redirect: "manual", headers: { "x-forwarded-proto": "https", "x-forwarded-host": "app.example.com" } });
    assert.match(signIn.headers.getSetCookie()[0]!, /; Secure$/);
  });
});

test("every Set-Cookie is its own header, and bodies stream", async () => {
  const handler = toNodeHandler(async () => {
    const headers = new Headers({ "content-type": "text/plain", "x-one": "1" });
    headers.append("set-cookie", "a=1; Path=/");
    headers.append("set-cookie", "b=2; Path=/; HttpOnly");
    const encoder = new TextEncoder();
    const body = new ReadableStream<Uint8Array>({
      async start(controller) {
        for (const part of ["one ", "two ", "three"]) {
          controller.enqueue(encoder.encode(part));
          await new Promise((r) => setTimeout(r, 5));
        }
        controller.close();
      },
    });
    return new Response(body, { status: 201, headers });
  });
  await serving(handler, async (base) => {
    const res = await fetch(base);
    assert.equal(res.status, 201);
    assert.deepEqual(res.headers.getSetCookie(), ["a=1; Path=/", "b=2; Path=/; HttpOnly"]);
    assert.equal(res.headers.get("x-one"), "1");
    assert.equal(await res.text(), "one two three");
    const head = await fetch(base, { method: "HEAD" });
    assert.equal(head.status, 201);
    assert.equal(head.headers.getSetCookie().length, 2);
    assert.equal(await head.text(), "", "a HEAD response has no body");
  });
});

test("without next, a basePath miss is a 404 and a thrown error a 500", async () => {
  await serving(toNodeHandler(async () => new Response("in"), { basePath: "/cronwatch/" }), async (base) => {
    assert.equal(await (await fetch(`${base}/cronwatch/x`)).text(), "in");
    assert.equal((await fetch(`${base}/other`)).status, 404);
  });
  await serving(toNodeHandler(async () => { throw new Error("boom"); }), async (base) => {
    const res = await fetch(base);
    assert.equal(res.status, 500);
    assert.equal(await res.text(), "Internal Server Error");
  });
});
