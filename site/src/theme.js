// Loaded in <head>, before the stylesheet and without defer. The pages are
// served dark (data-theme="dark" on <html>), so a reader who turned the
// sheet over to light paper sees it from the first paint. The toggle itself
// lives in site.js.
(function () {
  try {
    if (localStorage.getItem("cronwatch-theme") === "light") {
      document.documentElement.removeAttribute("data-theme");
      var meta = document.querySelector('meta[name="theme-color"]');
      if (meta) meta.setAttribute("content", "#f4f4f5");
    }
  } catch (e) {}
})();
