<?php

declare(strict_types=1);

namespace Cronwatch\Web;

use Cronwatch\Js;

/**
 * What makes the dashboard an installable web app, as the SDK's
 * routes/pwa.ts has it: a manifest, icons, a service worker, the script that
 * registers it and a page to show offline. None of it says anything about
 * the jobs, so it is served without the token (a browser fetches the
 * manifest and icons without cookies in some flows).
 *
 * @internal
 */
final class Pwa
{
    /** The page colours the app's window takes: the paper behind the sheet, and the sheet the header sits on. */
    public const BACKGROUND_COLOR = '#f4f4f5';
    public const THEME_COLOR = '#ffffff';
    public const THEME_COLOR_DARK = '#111113';

    /**
     * Registers the service worker, and does nothing else. The page works
     * the same without it. Its own URL gives the base, so it is the same text
     * wherever the dashboard is mounted.
     */
    public const APP_JS = <<<'JS'
"use strict";
(function () {
  var script = document.currentScript;
  if (!script || !("serviceWorker" in navigator)) return;
  var base = new URL("./", script.src);
  navigator.serviceWorker.register(new URL("sw.js", base).href, { scope: base.pathname }).catch(function () {});
})();

JS;

    /**
     * The service worker. It caches the app shell (the offline page, the
     * manifest, the icons and app.js) and nothing else: every other request
     * goes to the network as the page made it, and its answer is never
     * stored, since the pages and the JSON carry job data. When a page cannot
     * be reached it shows the offline page. Its scope gives the base, so it is
     * the same text wherever the dashboard is mounted.
     */
    public const SW_JS = <<<'JS'
"use strict";
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

JS;

    private const YEAR = 'public, max-age=31536000, immutable';
    private const REVALIDATE = 'no-cache';

    /** The manifest, for the dashboard mounted at `base` ("" at the root). */
    public static function manifest(string $base): string
    {
        $icon = fn (string $name, string $sizes, string $type, string $purpose): array => ['src' => "{$base}/icons/{$name}", 'sizes' => $sizes, 'type' => $type, 'purpose' => $purpose];
        return Js::stringify([
            'id' => "{$base}/",
            'name' => 'CronWatch',
            'short_name' => 'CronWatch',
            'description' => 'The scheduled jobs of this app: their health, their last day and their runs.',
            'start_url' => "{$base}/",
            'scope' => "{$base}/",
            'display' => 'standalone',
            'background_color' => self::BACKGROUND_COLOR,
            'theme_color' => self::THEME_COLOR,
            'icons' => [
                $icon('icon.svg', 'any', 'image/svg+xml', 'any'),
                $icon('maskable.svg', 'any', 'image/svg+xml', 'maskable'),
                $icon('icon-192.png', '192x192', 'image/png', 'any'),
                $icon('icon-512.png', '512x512', 'image/png', 'any'),
                $icon('maskable-512.png', '512x512', 'image/png', 'maskable'),
            ],
        ]);
    }

    /**
     * The app shell file at `path` (the path under the base), or null: its
     * type, body, cache rule, and whether it is the service worker. The
     * offline page is HTML and is served by the routes themselves.
     *
     * @return array{type: string, body: string, cache: string, worker: bool}|null
     */
    public static function asset(string $path, string $base): ?array
    {
        $asset = fn (string $type, string $body, string $cache, bool $worker = false): array => ['type' => $type, 'body' => $body, 'cache' => $cache, 'worker' => $worker];
        return match ($path) {
            '/manifest.webmanifest' => $asset('application/manifest+json', self::manifest($base), self::REVALIDATE),
            '/app.js' => $asset('text/javascript; charset=utf-8', self::APP_JS, self::REVALIDATE),
            '/sw.js' => $asset('text/javascript; charset=utf-8', self::SW_JS, self::REVALIDATE, true),
            '/icons/icon.svg' => $asset('image/svg+xml', Icons::ICON_SVG, self::YEAR),
            '/icons/maskable.svg' => $asset('image/svg+xml', Icons::MASKABLE_SVG, self::YEAR),
            '/icons/icon-192.png' => $asset('image/png', (string) base64_decode(Icons::ICON_192_PNG, true), self::YEAR),
            '/icons/icon-512.png' => $asset('image/png', (string) base64_decode(Icons::ICON_512_PNG, true), self::YEAR),
            '/icons/maskable-512.png' => $asset('image/png', (string) base64_decode(Icons::MASKABLE_512_PNG, true), self::YEAR),
            '/icons/apple-touch-icon.png' => $asset('image/png', (string) base64_decode(Icons::APPLE_TOUCH_ICON_PNG, true), self::YEAR),
            default => null,
        };
    }
}
