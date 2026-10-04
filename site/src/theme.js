// Loaded in <head>, before the stylesheets and without defer, so it runs
// without waiting on any of them. The pages are served dark
// (data-theme="dark" on <html>), so a reader who turned the sheet over to
// light paper sees it from the first paint. The toggle itself lives in
// site.js. The .js class lets the stylesheet lay out what site.js will
// enhance (the install tabs) before it runs, so nothing shifts when it does.
(function () {
  document.documentElement.classList.add("js");
  try {
    if (localStorage.getItem("cronwatch-theme") === "light") {
      document.documentElement.removeAttribute("data-theme");
      var meta = document.querySelector('meta[name="theme-color"]');
      if (meta) meta.setAttribute("content", "#f4f4f5");
    }
  } catch (e) {}
})();
