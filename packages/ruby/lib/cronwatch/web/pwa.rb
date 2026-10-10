# frozen_string_literal: true

module Cronwatch
  class Web
    # What makes the dashboard an installable web app, as the SDK's
    # routes/pwa.ts has it: a manifest, icons, a service worker, the script
    # that registers it, and a page to show offline. None of it says anything
    # about the jobs, so it is served without the token (a browser fetches the
    # manifest and icons without cookies in some flows).
    #
    # @api private
    module PWA
      # The page colours the app's window takes: the paper behind the sheet,
      # and the sheet the header sits on.
      BACKGROUND_COLOR = "#f4f4f5"
      THEME_COLOR = "#ffffff"
      THEME_COLOR_DARK = "#111113"

      # Registers the service worker, and switches between light and dark on
      # Cmd+Shift+D (Ctrl+Shift+D elsewhere), keeping the choice in
      # localStorage. The page works the same without it. Its own URL gives the base, so it is the same
      # text wherever the dashboard is mounted.
      APP_JS = <<~'JS'
        "use strict";
        (function () {
          var root = document.documentElement;
          try {
            var stored = localStorage.getItem("cronwatch-theme");
            if (stored === "light" || stored === "dark") root.setAttribute("data-theme", stored);
          } catch (e) {}
          document.addEventListener("keydown", function (event) {
            if (!(event.metaKey || event.ctrlKey) || !event.shiftKey || event.altKey || event.code !== "KeyD") return;
            event.preventDefault();
            var shown = root.getAttribute("data-theme") || (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
            var next = shown === "dark" ? "light" : "dark";
            root.setAttribute("data-theme", next);
            try { localStorage.setItem("cronwatch-theme", next); } catch (e) {}
          });
        })();
        (function () {
          var script = document.currentScript;
          if (!script || !("serviceWorker" in navigator)) return;
          var base = new URL("./", script.src);
          navigator.serviceWorker.register(new URL("sw.js", base).href, { scope: base.pathname }).catch(function () {});
        })();
      JS

      # The service worker. It caches the app shell (the offline page, the
      # manifest, the icons, and app.js) and nothing else: every other request
      # goes to the network as the page made it, and its answer is never
      # stored, since the pages and the JSON carry job data. When a page
      # cannot be reached it shows the offline page. Its scope gives the base,
      # so it is the same text wherever the dashboard is mounted.
      SW_JS = <<~'JS'
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
      JS

      # One app shell file: its type, body, and Cache-Control, and whether it
      # is the service worker (which may control everything under the base).
      Asset = Struct.new(:type, :body, :cache, :worker, keyword_init: true)

      YEAR = "public, max-age=31536000, immutable"
      REVALIDATE = "no-cache"

      ICONS = {
        "/icons/icon.svg" => ["image/svg+xml", Icons::ICON_SVG, false],
        "/icons/maskable.svg" => ["image/svg+xml", Icons::MASKABLE_SVG, false],
        "/icons/icon-192.png" => ["image/png", Icons::ICON_192_PNG, true],
        "/icons/icon-512.png" => ["image/png", Icons::ICON_512_PNG, true],
        "/icons/maskable-512.png" => ["image/png", Icons::MASKABLE_512_PNG, true],
        "/icons/apple-touch-icon.png" => ["image/png", Icons::APPLE_TOUCH_ICON_PNG, true],
      }.freeze

      module_function

      # The manifest, for the dashboard mounted at `base` ("" at the root).
      def manifest(base)
        icon = ->(name, sizes, type, purpose) { { src: "#{base}/icons/#{name}", sizes: sizes, type: type, purpose: purpose } }
        JS.json({
          id: "#{base}/",
          name: "CronWatch",
          short_name: "CronWatch",
          description: "The scheduled jobs of this app: their health, their last day, and their runs.",
          start_url: "#{base}/",
          scope: "#{base}/",
          display: "standalone",
          background_color: BACKGROUND_COLOR,
          theme_color: THEME_COLOR,
          icons: [
            icon.call("icon.svg", "any", "image/svg+xml", "any"),
            icon.call("maskable.svg", "any", "image/svg+xml", "maskable"),
            icon.call("icon-192.png", "192x192", "image/png", "any"),
            icon.call("icon-512.png", "512x512", "image/png", "any"),
            icon.call("maskable-512.png", "512x512", "image/png", "maskable"),
          ],
        })
      end

      # The app shell file at `path` (the path under the base), or nil. The
      # offline page is HTML and is served by the app itself.
      def asset(path, base)
        case path
        when "/manifest.webmanifest" then Asset.new(type: "application/manifest+json", body: manifest(base), cache: REVALIDATE)
        when "/app.js" then Asset.new(type: "text/javascript; charset=utf-8", body: APP_JS, cache: REVALIDATE)
        when "/sw.js" then Asset.new(type: "text/javascript; charset=utf-8", body: SW_JS, cache: REVALIDATE, worker: true)
        else
          type, body, binary = ICONS[path]
          return nil if type.nil?

          Asset.new(type: type, body: binary ? body.unpack1("m0") : body, cache: YEAR)
        end
      end
    end
  end
end
