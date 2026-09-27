import assert from "node:assert/strict";
import { test } from "node:test";
import vm from "node:vm";
import { cronwatch } from "../src/index.js";
import { capture, clock } from "./helpers.js";

function app(options: { token?: string | null; basePath?: string } = {}) {
  const c = clock();
  const cw = cronwatch({ now: c.now, alerts: [capture()], cronSecret: null });
  const routes = cw.routes({ token: "tok", basePath: "/cronwatch", ...options });
  const send = (method: string, path: string, headers: Record<string, string> = {}) =>
    routes.handler(new Request(`http://app.test${path}`, { method, headers }));
  const get = (path: string, headers: Record<string, string> = {}) => send("GET", path, headers);
  return { cw, routes, send, get, bearer: { authorization: "Bearer tok" } };
}

const CSP = "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; img-src 'self' data:; manifest-src 'self'; worker-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'";

test("the manifest describes the app at its base path, without the token", async () => {
  const { get } = app();
  const res = await get("/cronwatch/manifest.webmanifest");
  assert.equal(res.status, 200);
  assert.equal(res.headers.get("content-type"), "application/manifest+json");
  assert.equal(res.headers.get("x-content-type-options"), "nosniff");
  const manifest = await res.json();
  assert.equal(manifest.name, "CronWatch");
  assert.equal(manifest.short_name, "CronWatch");
  assert.equal(manifest.id, "/cronwatch/");
  assert.equal(manifest.start_url, "/cronwatch/");
  assert.equal(manifest.scope, "/cronwatch/");
  assert.equal(manifest.display, "standalone");
  assert.equal(manifest.background_color, "#f4f4f5");
  assert.equal(manifest.theme_color, "#ffffff");
  assert.deepEqual(manifest.icons.map((i: { src: string; sizes: string; type: string; purpose: string }) => [i.src, i.sizes, i.type, i.purpose]), [
    ["/cronwatch/icons/icon.svg", "any", "image/svg+xml", "any"],
    ["/cronwatch/icons/maskable.svg", "any", "image/svg+xml", "maskable"],
    ["/cronwatch/icons/icon-192.png", "192x192", "image/png", "any"],
    ["/cronwatch/icons/icon-512.png", "512x512", "image/png", "any"],
    ["/cronwatch/icons/maskable-512.png", "512x512", "image/png", "maskable"],
  ]);
});

test("the manifest follows the base path wherever the routes are mounted", async () => {
  for (const [basePath, prefix, base] of [["", "", ""], ["/", "", ""], ["/ops/cron/", "/ops/cron", "/ops/cron"]] as const) {
    const { get } = app({ basePath });
    const manifest = await (await get(`${prefix}/manifest.webmanifest`)).json();
    assert.equal(manifest.start_url, `${base}/`, basePath);
    assert.equal(manifest.scope, `${base}/`, basePath);
    assert.equal(manifest.id, `${base}/`, basePath);
    assert.equal(manifest.icons[0].src, `${base}/icons/icon.svg`, basePath);
    const sw = await get(`${prefix}/sw.js`);
    assert.equal(sw.headers.get("service-worker-allowed"), `${base}/`, basePath);
  }
});

/** Width and height from a PNG's IHDR. */
function pngSize(bytes: Uint8Array): [number, number] {
  assert.deepEqual([...bytes.subarray(0, 8)], [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a], "a PNG signature");
  const view = new DataView(bytes.buffer, bytes.byteOffset);
  return [view.getUint32(16), view.getUint32(20)];
}

test("icons are served with their types, a long cache and no token", async () => {
  const { get } = app();
  for (const [name, size] of [["icon-192.png", 192], ["icon-512.png", 512], ["maskable-512.png", 512], ["apple-touch-icon.png", 180]] as const) {
    const res = await get(`/cronwatch/icons/${name}`);
    assert.equal(res.status, 200, name);
    assert.equal(res.headers.get("content-type"), "image/png", name);
    assert.equal(res.headers.get("cache-control"), "public, max-age=31536000, immutable", name);
    assert.equal(res.headers.get("x-content-type-options"), "nosniff", name);
    assert.equal(res.headers.get("set-cookie"), null, name);
    const bytes = new Uint8Array(await res.arrayBuffer());
    assert.deepEqual(pngSize(bytes), [size, size], name);
    assert.ok(bytes.length < 10_000, `${name} is small (${bytes.length} bytes)`);
  }
  for (const name of ["icon.svg", "maskable.svg"]) {
    const res = await get(`/cronwatch/icons/${name}`);
    assert.equal(res.status, 200, name);
    assert.equal(res.headers.get("content-type"), "image/svg+xml", name);
    assert.equal(res.headers.get("content-security-policy"), "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'", name);
    const svg = await res.text();
    assert.match(svg, /<circle cx="20" cy="20" r="10.5"[^>]*stroke-width="2"/, name);
    assert.match(svg, /<path d="M20 12.5V20h6"[^>]*stroke-linecap="round"/, name);
    assert.doesNotMatch(svg, /<script|\son[a-z]+=/i, name);
  }
  assert.equal((await get("/cronwatch/icons/nope.png")).status, 401, "anything else under /icons needs the token");
});

test("the app shell is public even when the routes are locked or opened, and says nothing about jobs", async () => {
  const before = { NODE_ENV: process.env.NODE_ENV, CRONWATCH_TOKEN: process.env.CRONWATCH_TOKEN };
  process.env.NODE_ENV = "production";
  delete process.env.CRONWATCH_TOKEN;
  try {
    const locked = app({ token: undefined });
    await locked.cw.run("secret-job", async () => {});
    assert.equal((await locked.get("/cronwatch/")).status, 503);
    for (const path of ["/cronwatch/manifest.webmanifest", "/cronwatch/sw.js", "/cronwatch/app.js", "/cronwatch/offline", "/cronwatch/icons/icon.svg"]) {
      const res = await locked.get(path);
      assert.equal(res.status, 200, path);
      assert.doesNotMatch(await res.text(), /secret-job/, path);
    }
  } finally {
    for (const [k, v] of Object.entries(before)) {
      if (v === undefined) delete process.env[k]; else process.env[k] = v;
    }
  }
  const open = app({ token: null });
  assert.equal((await open.get("/cronwatch/manifest.webmanifest")).status, 200);
});

test("only GET and HEAD reach the app shell; a write there still needs the token", async () => {
  const { send, bearer } = app();
  assert.equal((await send("HEAD", "/cronwatch/sw.js")).status, 200);
  assert.equal((await send("POST", "/cronwatch/sw.js")).status, 401);
  assert.equal((await send("POST", "/cronwatch/manifest.webmanifest", bearer)).status, 404);
});

test("pages link the manifest, icons and app.js under the base, and set theme colours", async () => {
  const { cw, get, bearer } = app({ basePath: "/ops/cron" });
  await cw.run("h", async () => {});
  for (const path of ["/ops/cron/", "/ops/cron/jobs/h", "/ops/cron/nope", "/ops/cron/offline"]) {
    const html = await (await get(path, bearer)).text();
    assert.match(html, /<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">/, path);
    assert.match(html, /<link rel="manifest" href="\/ops\/cron\/manifest.webmanifest">/, path);
    assert.match(html, /<link rel="icon" href="\/ops\/cron\/icons\/icon.svg" type="image\/svg\+xml">/, path);
    assert.match(html, /<link rel="apple-touch-icon" href="\/ops\/cron\/icons\/apple-touch-icon.png">/, path);
    assert.match(html, /<meta name="theme-color" content="#ffffff" media="\(prefers-color-scheme: light\)">/, path);
    assert.match(html, /<meta name="theme-color" content="#111113" media="\(prefers-color-scheme: dark\)">/, path);
    assert.match(html, /<meta name="mobile-web-app-capable" content="yes">/, path);
    assert.match(html, /<meta name="apple-mobile-web-app-capable" content="yes">/, path);
    assert.match(html, /<meta name="apple-mobile-web-app-title" content="CronWatch">/, path);
    assert.deepEqual(html.match(/<script[^>]*>[^<]*<\/script>/g), [`<script src="/ops/cron/app.js" defer></script>`], `${path}: one script, external`);
    assert.match(html, /@media\(display-mode:standalone\)\{\n\.top\{position:sticky;top:0/, path);
    assert.match(html, /env\(safe-area-inset-left\)/, path);
  }
});

test("the page CSP allows exactly the app shell, and data stays uncacheable", async () => {
  const { cw, get, bearer } = app();
  await cw.run("h", async () => {});
  for (const path of ["/cronwatch/", "/cronwatch/jobs/h", "/cronwatch/nope", "/cronwatch/offline"]) {
    assert.equal((await get(path, bearer)).headers.get("content-security-policy"), CSP, path);
  }
  for (const path of ["/cronwatch/", "/cronwatch/jobs/h", "/cronwatch/api/jobs", "/cronwatch/api/jobs/h"]) {
    assert.equal((await get(path, bearer)).headers.get("cache-control"), "no-store", path);
  }
  assert.equal((await get("/cronwatch/")).headers.get("cache-control"), "no-store", "the sign-in page too");
});

test("the offline page is public, plain and says why", async () => {
  const { get } = app();
  const res = await get("/cronwatch/offline");
  assert.equal(res.status, 200);
  assert.equal(res.headers.get("content-type"), "text/html; charset=utf-8");
  assert.equal(res.headers.get("cache-control"), "no-cache");
  assert.equal(res.headers.get("x-frame-options"), "DENY");
  const html = await res.text();
  assert.match(html, /<h1>You are offline<\/h1><p>CronWatch shows live data from your app, so it needs a connection.<\/p>/);
});

test("app.js registers the service worker and does nothing else", async () => {
  const { get } = app();
  const res = await get("/cronwatch/app.js");
  assert.equal(res.headers.get("content-type"), "text/javascript; charset=utf-8");
  assert.equal(res.headers.get("cache-control"), "no-cache");
  const js = await res.text();
  assert.doesNotMatch(js, /fetch|cookie|Storage|XMLHttpRequest|innerHTML|eval|import/);
  const registered: [string, unknown][] = [];
  const context = {
    URL,
    document: { currentScript: { src: "https://app.example/ops/cron/app.js" } },
    navigator: { serviceWorker: { register: (url: string, options: unknown) => { registered.push([url, options]); return Promise.resolve(); } } },
  };
  vm.runInNewContext(js, context);
  assert.deepEqual(JSON.parse(JSON.stringify(registered)), [["https://app.example/ops/cron/sw.js", { scope: "/ops/cron/" }]]);
  // Without service workers it does nothing at all.
  vm.runInNewContext(js, { URL, document: context.document, navigator: {} });
});

/** Runs sw.js with a scope, fake caches and a fake network, and returns its listeners and what it stored. */
function worker(js: string, scope: string, online: boolean) {
  const listeners: Record<string, (event: unknown) => void> = {};
  const stored: string[] = [];
  const store = new Map<string, Response>();
  const cache = {
    addAll: async (requests: Request[]) => {
      for (const r of requests) {
        assert.equal(r.credentials, "omit", "the shell is fetched without cookies");
        stored.push(r.url);
        store.set(r.url, new Response(`cached ${new URL(r.url).pathname}`));
      }
    },
    put: async (request: Request | string) => { stored.push(typeof request === "string" ? request : request.url); },
    match: async (url: string) => store.get(url)?.clone(),
  };
  const fetched: string[] = [];
  const context = {
    URL, Request, Response, Promise,
    self: {
      registration: { scope },
      addEventListener: (type: string, fn: (event: unknown) => void) => { listeners[type] = fn; },
      skipWaiting: async () => {},
      clients: { claim: async () => {} },
    },
    caches: { open: async () => cache, keys: async () => [], delete: async () => true },
    fetch: async (request: Request) => {
      fetched.push(request.url);
      if (!online) throw new TypeError("Failed to fetch");
      return new Response("from the network", { headers: { "cache-control": "no-store" } });
    },
  };
  vm.runInNewContext(js, context);
  return { listeners, stored, fetched };
}

async function fire(listener: (event: unknown) => void, request?: Request): Promise<Response | null> {
  let responded: Promise<Response> | null = null;
  let waited: Promise<unknown> | null = null;
  listener({ request, respondWith: (p: Promise<Response>) => { responded = p; }, waitUntil: (p: Promise<unknown>) => { waited = p; } });
  if (waited) await waited;
  return responded ? await responded : null;
}

test("the service worker caches only the app shell, and never a page or the API", async () => {
  const { get } = app();
  const res = await get("/cronwatch/sw.js");
  assert.equal(res.status, 200);
  assert.equal(res.headers.get("content-type"), "text/javascript; charset=utf-8");
  assert.equal(res.headers.get("service-worker-allowed"), "/cronwatch/");
  assert.equal(res.headers.get("cache-control"), "no-cache");
  const js = await res.text();
  assert.doesNotMatch(js, /\.put\(/, "nothing is added after install");

  const scope = "https://app.example/cronwatch/";
  const online = worker(js, scope, true);
  await fire(online.listeners.install!);
  assert.deepEqual(online.stored.map((u) => new URL(u).pathname), [
    "/cronwatch/offline", "/cronwatch/manifest.webmanifest", "/cronwatch/app.js",
    "/cronwatch/icons/icon.svg", "/cronwatch/icons/maskable.svg", "/cronwatch/icons/icon-192.png",
    "/cronwatch/icons/icon-512.png", "/cronwatch/icons/maskable-512.png", "/cronwatch/icons/apple-touch-icon.png",
  ]);
  await fire(online.listeners.activate!);

  // A Request cannot be made with mode "navigate" outside a browser, so a navigation is its shape.
  const navigate = (path: string) => ({ url: `https://app.example${path}`, method: "GET", mode: "navigate" }) as unknown as Request;
  // Pages go to the network and come back untouched.
  const page = await fire(online.listeners.fetch!, navigate("/cronwatch/jobs/nightly"));
  assert.equal(await page!.text(), "from the network");
  // The API and writes are left to the browser entirely.
  assert.equal(await fire(online.listeners.fetch!, new Request(`${scope}api/jobs`)), null);
  assert.equal(await fire(online.listeners.fetch!, new Request(`${scope}check`, { method: "POST" })), null);
  // Shell files come from the cache.
  assert.equal(await (await fire(online.listeners.fetch!, new Request(`${scope}icons/icon.svg`)))!.text(), "cached /cronwatch/icons/icon.svg");
  assert.equal(online.stored.length, 9, "nothing stored beyond the shell");

  // Offline, a page gets the offline page; the API still goes to the network and fails there.
  const offline = worker(js, scope, false);
  await fire(offline.listeners.install!);
  const shown = await fire(offline.listeners.fetch!, navigate("/cronwatch/"));
  assert.equal(await shown!.text(), "cached /cronwatch/offline");
  assert.equal(await fire(offline.listeners.fetch!, new Request(`${scope}api/jobs`)), null);
  assert.equal(offline.stored.length, 9);
});

test("the sign-in cookie is scoped to the base, so the installed app shares it", async () => {
  const { get } = app({ basePath: "/ops/cron" });
  const res = await get("/ops/cron/?token=tok");
  assert.match(res.headers.get("set-cookie")!, /; Path=\/ops\/cron; HttpOnly; SameSite=Lax/);
});

test("the sign-in page takes the token in a form, for an installed app with no address bar", async () => {
  const { get } = app({ basePath: "/ops/cron" });
  const page = await get("/ops/cron/jobs/x");
  assert.equal(page.status, 401);
  const html = await page.text();
  assert.match(html, /<form class="signin" method="get" action="\/ops\/cron\/"><label for="token">Token<\/label><input id="token" name="token" type="password" autocomplete="current-password"[^>]*required><button class="primary" type="submit">Sign in<\/button><\/form>/);
  // What the form sends is the ?token= sign-in.
  const res = await get("/ops/cron/?token=tok");
  assert.equal(res.status, 303);
  assert.equal(res.headers.get("location"), "/ops/cron/");
  // Other pages do not carry it.
  assert.doesNotMatch(await (await get("/ops/cron/offline")).text(), /class="signin"/);
});
