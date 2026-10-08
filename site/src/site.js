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
    document.querySelectorAll(".theme").forEach(function (b) { b.setAttribute("aria-label", dark ? "Switch to light" : "Switch to dark"); });
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

  // Figures that animate do so once, when they first scroll into view. Until
  // this runs they are drawn complete, so a reader without script, or who
  // asked for less motion, sees the finished picture.
  var reduce = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (!reduce && "IntersectionObserver" in window) {
    var seen = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting) return;
        entry.target.classList.add("play");
        seen.unobserve(entry.target);
      });
    }, { threshold: 0.35 });
    document.querySelectorAll(".play-on-view").forEach(function (el) {
      el.classList.add("armed");
      seen.observe(el);
    });
  }

  // The contact form sends how long the page was open, measured here, so a
  // clock that is wrong on either side does not matter. The service turns
  // away a form sent within three seconds of loading; without script the
  // field stays empty and the message still goes.
  var opened = Date.now();
  document.querySelectorAll("form.contact").forEach(function (form) {
    form.addEventListener("submit", function () {
      var t = form.querySelector('input[name="t"]');
      if (t) t.value = String(Date.now() - opened);
    });
  });

  // The docs sidebar sticks 24px from the top, but until the page has
  // scrolled that far it starts lower, under the masthead. Its list scrolls
  // inside it, so its height has to end above the bottom of the window from
  // wherever it starts: tell the stylesheet how much room there is. Without
  // script it assumes the lower start, which fits either way.
  var side = document.querySelector(".docs-side");
  if (side) {
    var queued = false;
    var room = function () {
      queued = false;
      var top = Math.max(side.getBoundingClientRect().top, 24);
      side.style.setProperty("--side-room", Math.max(160, Math.floor(window.innerHeight - top - 24)) + "px");
    };
    var later = function () { if (!queued) { queued = true; requestAnimationFrame(room); } };
    window.addEventListener("scroll", later, { passive: true });
    window.addEventListener("resize", later);
    room();
  }

  // The install boxes as tabs, one per language. The last one chosen is
  // remembered in this browser; without script every box shows.
  document.querySelectorAll(".installs").forEach(function (installs) {
    var list = installs.querySelector("[role=tablist]");
    if (!list) return;
    var tabs = Array.prototype.slice.call(list.querySelectorAll("[role=tab]"));
    var choose = function (tab, focus) {
      tabs.forEach(function (t) {
        var on = t === tab;
        t.setAttribute("aria-selected", on ? "true" : "false");
        t.tabIndex = on ? 0 : -1;
        document.getElementById(t.getAttribute("aria-controls")).hidden = !on;
      });
      if (focus) tab.focus();
    };
    var stored = null;
    try { stored = localStorage.getItem("cronwatch-install"); } catch (e) {}
    var remembered = tabs.filter(function (t) { return t.id === stored; })[0];
    choose(remembered || tabs[0], false);
    list.hidden = false;
    installs.classList.add("tabbed");
    tabs.forEach(function (tab, i) {
      tab.addEventListener("click", function () {
        choose(tab, false);
        try { localStorage.setItem("cronwatch-install", tab.id); } catch (e) {}
      });
      tab.addEventListener("keydown", function (event) {
        var next = { ArrowRight: i + 1, ArrowLeft: i - 1, Home: 0, End: tabs.length - 1 }[event.key];
        if (next === undefined) return;
        event.preventDefault();
        tabs[(next + tabs.length) % tabs.length].click();
        tabs[(next + tabs.length) % tabs.length].focus();
      });
    });
  });

  // A docs page's markdown, fetched from beside it. Safari only writes to the
  // clipboard within the click, so where it can the fetch goes inside the
  // clipboard item rather than before it.
  document.querySelectorAll(".copy-md").forEach(function (button) {
    var label = button.textContent;
    var src = button.getAttribute("data-md");
    var text = function () { return fetch(src).then(function (r) { if (!r.ok) throw new Error(r.status); return r.text(); }); };
    var say = function (what) { return function () { button.textContent = what; setTimeout(function () { button.textContent = label; }, 1800); }; };
    button.hidden = !navigator.clipboard;
    button.addEventListener("click", function () {
      var write = window.ClipboardItem && navigator.clipboard.write
        ? navigator.clipboard.write([new ClipboardItem({ "text/plain": text().then(function (t) { return new Blob([t], { type: "text/plain" }); }) })])
            .catch(function () { return text().then(function (t) { return navigator.clipboard.writeText(t); }); })
        : text().then(function (t) { return navigator.clipboard.writeText(t); });
      write.then(say("Copied"), say("Could not copy"));
    });
  });

  document.querySelectorAll(".copy:not(.copy-md)").forEach(function (button) {
    button.addEventListener("click", function () {
      var box = button.closest(".install, .out");
      var code = box ? box.querySelector("code") : null;
      var text = code ? code.textContent : "";
      var done = function () { button.textContent = "Copied"; setTimeout(function () { button.textContent = "Copy"; }, 1500); };
      if (navigator.clipboard) navigator.clipboard.writeText(text).then(done, done); else done();
    });
  });
})();
