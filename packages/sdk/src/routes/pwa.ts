import { APPLE_TOUCH_ICON_PNG, ICON_192_PNG, ICON_512_PNG, ICON_SVG, MASKABLE_512_PNG, MASKABLE_SVG } from "./icons.js";

/*
 * What makes the dashboard an installable web app: a manifest, icons, a
 * service worker, the script that registers it and a page to show offline.
 * None of it says anything about the jobs, so it is served without the token
 * (a browser fetches the manifest and icons without cookies in some flows).
 */

/** The page colours the app's window takes: the paper behind the sheet, and the sheet the header sits on. */
export const BACKGROUND_COLOR = "#f4f4f5";
export const THEME_COLOR = "#ffffff";
export const THEME_COLOR_DARK = "#111113";

/** The manifest, for the dashboard mounted at `base` ("" at the root). */
export function manifest(base: string): string {
  const icon = (name: string, sizes: string, type: string, purpose: string) => ({ src: `${base}/icons/${name}`, sizes, type, purpose });
  return JSON.stringify({
    id: `${base}/`,
    name: "CronWatch",
    short_name: "CronWatch",
    description: "The scheduled jobs of this app: their health, their last day and their runs.",
    start_url: `${base}/`,
    scope: `${base}/`,
    display: "standalone",
    background_color: BACKGROUND_COLOR,
    theme_color: THEME_COLOR,
    icons: [
      icon("icon.svg", "any", "image/svg+xml", "any"),
      icon("maskable.svg", "any", "image/svg+xml", "maskable"),
      icon("icon-192.png", "192x192", "image/png", "any"),
      icon("icon-512.png", "512x512", "image/png", "any"),
      icon("maskable-512.png", "512x512", "image/png", "maskable"),
    ],
  });
}

/**
 * Registers the service worker, and does nothing else. The page works the
 * same without it. Its own URL gives the base, so it is the same text
 * wherever the dashboard is mounted.
 */
export const APP_JS = `"use strict";
(function () {
  var script = document.currentScript;
  if (!script || !("serviceWorker" in navigator)) return;
  var base = new URL("./", script.src);
  navigator.serviceWorker.register(new URL("sw.js", base).href, { scope: base.pathname }).catch(function () {});
})();
`;

/**
 * The service worker. It caches the app shell (the offline page, the
 * manifest, the icons and app.js) and nothing else: every other request goes
 * to the network as the page made it, and its answer is never stored, since
 * the pages and the JSON carry job data. When a page cannot be reached it
 * shows the offline page. Its scope gives the base, so it is the same text
 * wherever the dashboard is mounted.
 */
export const SW_JS = `"use strict";
var VERSION = "cronwatch-shell-1";
var SCOPE = self.registration.scope;
var CACHE = VERSION + " " + SCOPE;
var SHELL = ["offline", "manifest.webmanifest", "app.js", "icons/icon.svg", "icons/maskable.svg", "icons/icon-192.png", "icons/icon-512.png", "icons/maskable-512.png", "icons/apple-touch-icon.png"].map(function (path) {
  return new URL(path, SCOPE).href;
});
var OFFLINE = SHELL[0];

self.addEventListener("install", function (event) {
  event.waitUntil(caches.open(CACHE).then(function (cache) {
    return cache.addAll(SHELL.map(function (url) { return new Request(url, { credentials: "omit", cache: "reload" }); }));
  }).then(function () { return self.skipWaiting(); }));
});

self.addEventListener("activate", function (event) {
  event.waitUntil(caches.keys().then(function (keys) {
    return Promise.all(keys.filter(function (key) {
      return key !== CACHE && key.indexOf("cronwatch-shell-") === 0 && key.slice(key.indexOf(" ") + 1) === SCOPE;
    }).map(function (key) { return caches.delete(key); }));
  }).then(function () { return self.clients.claim(); }));
});

self.addEventListener("fetch", function (event) {
  var request = event.request;
  if (request.method !== "GET") return;
  var url = new URL(request.url);
  url.search = "";
  if (SHELL.indexOf(url.href) !== -1 && url.href !== OFFLINE) {
    event.respondWith(caches.open(CACHE).then(function (cache) {
      return cache.match(url.href).then(function (hit) { return hit || fetch(request); });
    }));
    return;
  }
  if (request.mode !== "navigate") return;
  event.respondWith(fetch(request).catch(function () {
    return caches.open(CACHE).then(function (cache) { return cache.match(OFFLINE); }).then(function (page) {
      return page || new Response("You are offline.", { status: 503, headers: { "content-type": "text/plain; charset=utf-8" } });
    });
  }));
});
`;

export interface StaticAsset {
  type: string;
  body: string | Uint8Array<ArrayBuffer>;
  cache: string;
  /** The service worker, which may control everything under the base. */
  worker?: boolean;
}

const YEAR = "public, max-age=31536000, immutable";
const REVALIDATE = "no-cache";

function decode(base64: string): Uint8Array<ArrayBuffer> {
  const bytes = atob(base64);
  const out = new Uint8Array(bytes.length);
  for (let i = 0; i < bytes.length; i++) out[i] = bytes.charCodeAt(i);
  return out;
}

const ICONS: Record<string, () => StaticAsset> = {
  "/icons/icon.svg": () => ({ type: "image/svg+xml", body: ICON_SVG, cache: YEAR }),
  "/icons/maskable.svg": () => ({ type: "image/svg+xml", body: MASKABLE_SVG, cache: YEAR }),
  "/icons/icon-192.png": () => ({ type: "image/png", body: decode(ICON_192_PNG), cache: YEAR }),
  "/icons/icon-512.png": () => ({ type: "image/png", body: decode(ICON_512_PNG), cache: YEAR }),
  "/icons/maskable-512.png": () => ({ type: "image/png", body: decode(MASKABLE_512_PNG), cache: YEAR }),
  "/icons/apple-touch-icon.png": () => ({ type: "image/png", body: decode(APPLE_TOUCH_ICON_PNG), cache: YEAR }),
};

/**
 * The app shell file at `path` (the path under the base), or null. The
 * offline page is HTML and is served by the routes themselves.
 */
export function staticAsset(path: string, base: string): StaticAsset | null {
  if (path === "/manifest.webmanifest") return { type: "application/manifest+json", body: manifest(base), cache: REVALIDATE };
  if (path === "/app.js") return { type: "text/javascript; charset=utf-8", body: APP_JS, cache: REVALIDATE };
  if (path === "/sw.js") return { type: "text/javascript; charset=utf-8", body: SW_JS, cache: REVALIDATE, worker: true };
  return Object.hasOwn(ICONS, path) ? ICONS[path]!() : null;
}
