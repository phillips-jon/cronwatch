// Loaded in <head>, before the stylesheet and without defer, so a reader who
// turned the sheet over sees dark paper from the first paint. The toggle
// itself lives in site.js.
(function () {
  try {
    if (localStorage.getItem("cronwatch-theme") === "dark") {
      document.documentElement.setAttribute("data-theme", "dark");
      var meta = document.querySelector('meta[name="theme-color"]');
      if (meta) meta.setAttribute("content", "#09090b");
    }
  } catch (e) {}
})();
