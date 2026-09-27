// Docs search: Cmd+K (Ctrl+K elsewhere) or the "Search docs" entry opens a
// dialog that searches every docs page by title, section heading and text.
// The index is a script build.mjs writes next to this one (the CSP allows no
// fetch), added the first time the dialog opens. Without script the entry is
// a plain link to the docs index.
(function () {
  var me = document.currentScript;
  var indexUrl = me && me.getAttribute("data-index");
  if (!indexUrl || !window.HTMLDialogElement) return;

  var mac = /Mac|iPhone|iPad/.test(navigator.platform || navigator.userAgent);
  var opens = document.querySelectorAll("[data-search-open]");
  opens.forEach(function (a) {
    a.setAttribute("role", "button");
    a.setAttribute("aria-haspopup", "dialog");
    a.setAttribute("aria-keyshortcuts", mac ? "Meta+K" : "Control+K");
    var kbd = a.querySelector("kbd");
    if (kbd) kbd.textContent = mac ? "⌘K" : "Ctrl K";
    a.addEventListener("click", function (e) {
      if (e.metaKey || e.ctrlKey || e.shiftKey || e.button !== 0) return;
      e.preventDefault();
      open(a);
    });
  });

  var dialog, input, list, status, opener, pages, loading = false;
  var results = [], active = -1, uid = 0;

  function el(tag, cls, text) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = text;
    return n;
  }

  function make() {
    dialog = el("dialog", "search");
    dialog.setAttribute("aria-label", "Search the docs");
    var box = el("div", "search-box");
    var field = el("div", "search-field");
    var label = el("label", "vh", "Search the docs");
    label.htmlFor = "search-q";
    input = el("input");
    input.id = "search-q";
    input.type = "search";
    input.placeholder = "Search docs";
    input.autocomplete = "off";
    input.spellcheck = false;
    input.setAttribute("role", "combobox");
    input.setAttribute("aria-autocomplete", "list");
    input.setAttribute("aria-expanded", "false");
    input.setAttribute("aria-controls", "search-results");
    var esc = el("button", "search-close", "Esc");
    esc.type = "button";
    esc.setAttribute("aria-label", "Close search");
    field.append(label, input, esc);
    list = el("ul", "search-results");
    list.id = "search-results";
    list.setAttribute("role", "listbox");
    list.setAttribute("aria-label", "Results");
    status = el("p", "search-status");
    status.setAttribute("role", "status");
    var hint = el("p", "search-hint");
    hint.setAttribute("aria-hidden", "true");
    [["↑↓", "move"], ["Enter", "open"], ["Esc", "close"]].forEach(function (k) {
      hint.append(el("kbd", null, k[0]), " " + k[1] + " ");
    });
    box.append(field, status, list, hint);
    dialog.append(box);
    document.body.append(dialog);

    input.addEventListener("input", run);
    input.addEventListener("keydown", keys);
    esc.addEventListener("click", function () { dialog.close(); });
    // A click outside the box lands on the dialog itself: the backdrop.
    dialog.addEventListener("click", function (e) { if (e.target === dialog) dialog.close(); });
    dialog.addEventListener("close", function () {
      document.documentElement.classList.remove("searching");
      if (opener && document.contains(opener)) opener.focus({ preventScroll: true });
    });
    list.addEventListener("mousemove", function (e) {
      var li = e.target.closest("li[role=option]");
      if (li) select(Number(li.getAttribute("data-i")), false);
    });
    list.addEventListener("click", function (e) {
      var li = e.target.closest("li[role=option]");
      if (li) go(Number(li.getAttribute("data-i")));
    });
  }

  function load() {
    if (pages || loading) return;
    if (window.cronwatchSearch) { pages = prepare(window.cronwatchSearch); return; }
    loading = true;
    status.textContent = "Loading the index";
    var s = document.createElement("script");
    s.src = indexUrl;
    s.onload = function () { loading = false; pages = prepare(window.cronwatchSearch || []); run(); };
    s.onerror = function () { loading = false; status.textContent = "The search index did not load. Try again after a reload."; };
    document.head.append(s);
  }

  function open(from) {
    if (!dialog) make();
    opener = from || document.activeElement;
    if (!dialog.open) {
      dialog.showModal();
      document.documentElement.classList.add("searching");
    }
    input.focus();
    input.select();
    load();
    run();
  }

  document.addEventListener("keydown", function (e) {
    if ((e.metaKey || e.ctrlKey) && !e.shiftKey && !e.altKey && e.key.toLowerCase() === "k") {
      e.preventDefault();
      if (dialog && dialog.open) { input.focus(); input.select(); } else open(document.activeElement);
    }
  });

  /* ---- Matching. ---- */

  // Lower case with accents taken off, keeping a map from each character of
  // the folded text back to the original, so a match can be marked in place.
  function fold(s) {
    var out = "", map = [];
    for (var i = 0; i < s.length; i++) {
      var f = s[i].normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase();
      for (var j = 0; j < f.length; j++) { out += f[j]; map.push(i); }
    }
    return { text: out, map: map, raw: s };
  }

  function prepare(data) {
    var out = [];
    data.forEach(function (p, pi) {
      var title = fold(p.t);
      p.s.forEach(function (s, si) {
        out.push({ page: p, order: pi * 1000 + si, title: title, head: fold(s[0] || ""), text: fold(s[2] || ""), anchor: s[1] });
      });
    });
    return out;
  }

  var WORD = /[a-z0-9]/;
  // How well one term matches one field: a whole word, the start of a word,
  // or anywhere inside one. Returns the score and where the match starts.
  function find(f, term) {
    var t = f.text, best = 0, at = -1, from = 0, i;
    while ((i = t.indexOf(term, from)) !== -1) {
      var start = i === 0 || !WORD.test(t[i - 1]);
      var end = i + term.length === t.length || !WORD.test(t[i + term.length]);
      var s = start && end ? 3 : start ? 2 : 1;
      if (s > best) { best = s; at = i; }
      if (best === 3) break;
      from = i + 1;
    }
    return { score: best, at: at };
  }

  function score(entry, terms, phrase) {
    var total = 0;
    for (var k = 0; k < terms.length; k++) {
      var h = entry.head.text ? find(entry.head, terms[k]).score : 0;
      var t = find(entry.title, terms[k]).score;
      var x = find(entry.text, terms[k]).score;
      if (!h && !t && !x) return 0;
      total += h * 4 + t * 3 + x;
    }
    if (terms.length > 1 && entry.head.text.indexOf(phrase) !== -1) total += 6;
    // The page itself (its opening text) ranks above its sections when the
    // title is what matched.
    if (!entry.head.text && terms.every(function (term) { return find(entry.title, term).score; })) total += 4;
    return total;
  }

  function run() {
    if (!dialog) return;
    var q = fold(input.value.trim()).text.replace(/\s+/g, " ");
    list.textContent = "";
    results = [];
    active = -1;
    input.removeAttribute("aria-activedescendant");
    input.setAttribute("aria-expanded", "false");
    status.classList.remove("vh");
    if (!pages) return;
    if (!q) { status.textContent = ""; return; }
    var terms = q.split(" ").filter(Boolean);
    results = pages.map(function (e) { return { e: e, s: score(e, terms, q) }; })
      .filter(function (r) { return r.s > 0; })
      .sort(function (a, b) { return b.s - a.s || a.e.order - b.e.order; })
      .slice(0, 30);
    input.setAttribute("aria-expanded", results.length ? "true" : "false");
    status.textContent = results.length ? results.length + (results.length === 1 ? " result" : " results") : "No results for “" + input.value.trim() + "”.";
    status.classList.toggle("vh", results.length > 0);
    var frag = document.createDocumentFragment();
    results.forEach(function (r, i) {
      var e = r.e;
      var li = el("li");
      li.id = "search-r" + (++uid);
      li.setAttribute("role", "option");
      li.setAttribute("aria-selected", "false");
      li.setAttribute("data-i", String(i));
      var where = el("span", "sr-page");
      where.append(markUp(e.title, terms));
      if (e.page.g) where.append(el("span", "sr-group", e.page.g));
      var head = el("span", "sr-head");
      head.append(markUp(e.head.text ? e.head : e.title, terms));
      var line = el("span", "sr-text");
      line.append(markUp(e.text, terms, true));
      li.append(where, head, line);
      frag.append(li);
    });
    list.append(frag);
    if (results.length) select(0, false);
  }

  // A field as text with each matched term in a <mark>. For an `excerpt`, the
  // text starts a little before the first match, so it shows on one line.
  function markUp(f, terms, excerpt) {
    var hits = [];
    terms.forEach(function (term) {
      var from = 0, i;
      while ((i = f.text.indexOf(term, from)) !== -1) {
        if (i === 0 || !WORD.test(f.text[i - 1]) || term.length > 2) hits.push([i, i + term.length]);
        from = i + term.length;
      }
    });
    hits.sort(function (a, b) { return a[0] - b[0]; });
    var merged = [];
    hits.forEach(function (h) {
      var last = merged[merged.length - 1];
      if (last && h[0] <= last[1]) last[1] = Math.max(last[1], h[1]); else merged.push(h.slice());
    });
    // Back to positions in the original text.
    var spans = merged.map(function (h) { return [f.map[h[0]], f.map[h[1] - 1] + 1]; });
    var raw = f.raw, start = 0;
    if (excerpt && spans.length && spans[0][0] > 48) {
      start = raw.lastIndexOf(" ", spans[0][0] - 36) + 1;
    }
    var frag = document.createDocumentFragment();
    if (start > 0) frag.append("…");
    var pos = start;
    spans.forEach(function (s) {
      if (s[1] <= pos) return;
      var a = Math.max(s[0], pos);
      if (a > pos) frag.append(raw.slice(pos, a));
      frag.append(el("mark", null, raw.slice(a, s[1])));
      pos = s[1];
    });
    if (pos < raw.length) frag.append(raw.slice(pos));
    return frag;
  }

  /* ---- Moving and going. ---- */

  function select(i, scroll) {
    if (i === active || i < 0 || i >= results.length) return;
    var items = list.children;
    if (items[active]) items[active].setAttribute("aria-selected", "false");
    active = i;
    items[i].setAttribute("aria-selected", "true");
    input.setAttribute("aria-activedescendant", items[i].id);
    if (scroll) items[i].scrollIntoView({ block: "nearest" });
  }

  function go(i) {
    var r = results[i];
    if (!r) return;
    var anchor = r.e.anchor;
    dialog.close();
    if (r.e.page.u !== location.pathname) { location.href = r.e.page.u + (anchor ? "#" + anchor : ""); return; }
    // Already on the page: move to the section, even when the address
    // already ends in its anchor.
    var target = anchor ? document.getElementById(anchor) : null;
    if (anchor && location.hash !== "#" + anchor) location.hash = anchor;
    else if (target) target.scrollIntoView();
    else if (!anchor) window.scrollTo(0, 0);
  }

  function keys(e) {
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault();
      if (!results.length) return;
      var n = results.length;
      select(((active + (e.key === "ArrowDown" ? 1 : -1)) % n + n) % n, true);
    } else if (e.key === "Escape") {
      // A search field would take the first Esc to clear itself.
      e.preventDefault();
      dialog.close();
    } else if (e.key === "Enter" && !e.isComposing) {
      e.preventDefault();
      go(active);
    }
  }
})();
