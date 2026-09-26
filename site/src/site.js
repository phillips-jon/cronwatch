// Light unless the reader chose otherwise (Shift+Cmd+D or the footer toggle),
// and the copy buttons. theme.js has already applied a stored choice.
(function () {
  var root = document.documentElement;
  var themeColor = document.querySelector('meta[name="theme-color"]');
  function toggle() {
    var dark = root.getAttribute("data-theme") !== "dark";
    if (dark) root.setAttribute("data-theme", "dark"); else root.removeAttribute("data-theme");
    try { localStorage.setItem("cronwatch-theme", dark ? "dark" : "light"); } catch (e) {}
    render();
  }
  function render() {
    var dark = root.getAttribute("data-theme") === "dark";
    document.querySelectorAll(".theme").forEach(function (b) { b.textContent = dark ? "Light paper" : "Dark paper"; });
    if (themeColor) themeColor.setAttribute("content", dark ? "#09090b" : "#f4f4f5");
  }
  document.addEventListener("keydown", function (e) {
    if (e.shiftKey && (e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "d") { e.preventDefault(); toggle(); }
  });
  document.querySelectorAll(".theme").forEach(function (b) { b.addEventListener("click", toggle); });
  render();

  var promptEl = document.getElementById("prompt-text");
  document.querySelectorAll("[data-prompt]").forEach(function (button) {
    var label = button.textContent;
    button.addEventListener("click", function () {
      var text = promptEl ? promptEl.textContent : "";
      if (!text) return;
      var done = function () {
        button.textContent = "Copied. Paste it into your agent.";
        setTimeout(function () { button.textContent = label; }, 2600);
      };
      if (navigator.clipboard) navigator.clipboard.writeText(text).then(done, done); else done();
    });
  });

  document.querySelectorAll(".copy").forEach(function (button) {
    button.addEventListener("click", function () {
      var box = button.closest(".install, .out");
      var code = box ? box.querySelector("code") : null;
      var text = code ? code.textContent : "";
      var done = function () { button.textContent = "Copied"; setTimeout(function () { button.textContent = "Copy"; }, 1500); };
      if (navigator.clipboard) navigator.clipboard.writeText(text).then(done, done); else done();
    });
  });
})();
