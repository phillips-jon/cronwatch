"use strict";
(function () {
  var script = document.currentScript;
  if (!script || !("serviceWorker" in navigator)) return;
  var base = new URL("./", script.src);
  navigator.serviceWorker.register(new URL("sw.js", base).href, { scope: base.pathname }).catch(function () {});
})();
