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
