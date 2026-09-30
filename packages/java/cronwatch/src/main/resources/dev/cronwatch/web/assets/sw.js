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
