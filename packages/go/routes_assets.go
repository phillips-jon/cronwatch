package cronwatch

// The dashboard's fixed text: its style sheet and mark (routes/html.ts), and
// the app shell's scripts (routes/pwa.ts), copied verbatim.

// dashboardCSS is the pages' style sheet.
const dashboardCSS = `
:root{color-scheme:light dark;--paper:#f4f4f5;--sheet:#fff;--sunk:#fafafa;--rule:#e4e4e7;--rule-2:#d4d4d8;--tick:#909098;--ink:#000;--body:#18181b;--muted:#71717a;--ok:#15803d;--warn:#a16207;--bad:#b91c1c;--serif:"Newsreader",ui-serif,Georgia,Cambria,"Times New Roman",serif;--mono:"IBM Plex Mono",ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;--who:200px}
@media(prefers-color-scheme:dark){:root:not([data-theme=light]){--paper:#09090b;--sheet:#111113;--sunk:#18181b;--rule:#27272a;--rule-2:#3f3f46;--tick:#66666f;--ink:#fff;--body:#e4e4e7;--muted:#a1a1aa;--ok:#4ade80;--warn:#fbbf24;--bad:#f87171}}
:root[data-theme=light]{color-scheme:light}:root[data-theme=dark]{color-scheme:dark;--paper:#09090b;--sheet:#111113;--sunk:#18181b;--rule:#27272a;--rule-2:#3f3f46;--tick:#66666f;--ink:#fff;--body:#e4e4e7;--muted:#a1a1aa;--ok:#4ade80;--warn:#fbbf24;--bad:#f87171}
*{box-sizing:border-box}html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--paper);color:var(--ink);font:400 16px/1.55 var(--serif);-webkit-font-smoothing:antialiased;-moz-osx-font-smoothing:grayscale}
a{color:inherit;text-decoration:underline;text-decoration-thickness:1px;text-underline-offset:.16em;text-decoration-color:var(--rule-2)}a:hover{text-decoration-color:currentColor}
:focus-visible{outline:2px solid var(--ink);outline-offset:2px}
code,pre,.mono{font-family:var(--mono)}
.vh{position:absolute!important;width:1px;height:1px;margin:-1px;padding:0;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap;border:0}
.sheet{max-width:1180px;min-height:100vh;margin:0 auto;background:var(--sheet);border-inline:1px solid var(--rule);padding:0 clamp(16px,4vw,48px)}
.top{display:flex;align-items:center;justify-content:space-between;gap:12px 20px;flex-wrap:wrap;padding:18px 0 17px;border-bottom:1px solid var(--rule)}
.brand{display:flex;align-items:center;gap:10px;margin:0;font:600 18px/1.2 var(--serif);letter-spacing:-.01em;min-width:0}
.brand a{display:inline-flex;align-items:center;gap:10px;text-decoration:none}.brand svg{width:24px;height:24px;flex:none;color:var(--ink)}
.brand .crumb{font:500 15px/1.2 var(--mono);color:var(--body);overflow-wrap:anywhere}.brand .slash{color:var(--rule-2);font-weight:400}
.actions{display:flex;align-items:center;gap:10px;flex-wrap:wrap}
.meta{font:400 12px/1.4 var(--mono);color:var(--muted)}
button,a.button,details.confirm>summary{font:500 12.5px/1 var(--mono);color:var(--ink);background:var(--sheet);border:1px solid var(--rule-2);border-radius:3px;height:32px;padding:0 11px;cursor:pointer}
a.button{display:inline-flex;align-items:center;text-decoration:none}
button:hover,a.button:hover,details.confirm>summary:hover{border-color:var(--muted)}
button.primary{background:var(--ink);border-color:var(--ink);color:var(--sheet)}button.primary:hover{opacity:.86}button.danger{color:var(--bad)}button.danger:hover{border-color:var(--bad)}
form.inline{display:inline-flex;align-items:center;gap:6px;margin:0}
details.confirm{display:inline-flex;align-items:center;flex-wrap:wrap;gap:8px;margin:0}details.confirm>summary{list-style:none;display:inline-flex;align-items:center}
details.confirm>summary::-webkit-details-marker{display:none}details.confirm[open]>summary{border-color:var(--muted)}
details.confirm form{flex-wrap:wrap;font-size:14px;color:var(--muted)}.delete details{margin-top:16px}
.sec{display:grid;grid-template-columns:150px minmax(0,1fr);gap:10px 40px;padding:30px 0;border-top:1px solid var(--rule)}
.top+main>.sec:first-child{border-top:0}
.sec>h2{margin:0;font:500 11px/1.5 var(--mono);letter-spacing:.12em;text-transform:uppercase;color:var(--muted);padding-top:5px}
.sec>.wide{grid-column:1/-1;min-width:0}
.lede{margin:0;color:var(--muted);font-size:16px;max-width:64ch;text-wrap:pretty}
.headline{margin:0;font:400 clamp(24px,3.2vw,32px)/1.2 var(--serif);letter-spacing:-.01em;text-wrap:balance}
.headline b{font-weight:600}
.state{font:500 12.5px/1.4 var(--mono);white-space:nowrap}.state+.state::before{content:" \00b7  ";color:var(--muted);font-weight:400}
.ok{color:var(--ok)}.warn{color:var(--warn)}.bad{color:var(--bad)}.muted{color:var(--muted)}.info{color:var(--ink)}
.sq{display:inline-block;width:8px;height:8px;border-radius:1.5px;background:currentColor;margin-right:7px;vertical-align:1px;flex:none}
.sq.muted{background:none;box-shadow:inset 0 0 0 1.5px var(--tick)}
.figures{display:grid;grid-template-columns:repeat(auto-fit,minmax(120px,1fr));gap:0;margin:22px 0 0;border-top:1px solid var(--rule)}
.figures>div{display:flex;flex-direction:column-reverse;justify-content:flex-end;gap:4px;padding:14px 16px 2px 0}
.figures dt{font:500 11px/1.4 var(--mono);letter-spacing:.08em;text-transform:uppercase;color:var(--muted);display:flex;align-items:center}
.figures dd{margin:0;font:400 30px/1.1 var(--serif);font-variant-numeric:tabular-nums;color:var(--ink)}
.figures dd small{font-size:17px;color:var(--muted)}
.figures .zero dd{color:var(--rule-2)}
.figures .bad dd{color:var(--bad)}.figures .warn dd{color:var(--warn)}
.stateline{margin:12px 0 0;display:flex;flex-wrap:wrap;align-items:baseline;gap:4px 12px}
.stateline .why{font-style:italic;color:var(--muted)}
.jobname{margin:0;font:500 clamp(22px,3vw,28px)/1.2 var(--mono);letter-spacing:-.01em;overflow-wrap:anywhere}
.desc{margin:6px 0 0;color:var(--body);max-width:64ch}
.intro .actions{margin-top:18px}
table{width:100%;border-collapse:collapse}
th{text-align:left;font:500 10.5px/1.2 var(--mono);letter-spacing:.08em;text-transform:uppercase;color:var(--muted);padding:0 14px 10px 0;border-bottom:1px solid var(--rule);white-space:nowrap}
td{padding:12px 14px 12px 0;border-bottom:1px solid var(--rule);vertical-align:top;font:400 12.5px/1.5 var(--mono);color:var(--body)}
tbody tr:last-child td{border-bottom:0}
td.job{font-family:var(--serif);font-size:15px;min-width:180px}
td.job .name{font:500 13.5px/1.5 var(--mono);color:var(--ink)}
td.job .desc{display:block;margin:2px 0 0;font-size:14px;color:var(--muted);line-height:1.4}
td .tz,td .sub{display:block;color:var(--muted);font-size:11.5px}
.nowrap{white-space:nowrap}
.spark{display:block;overflow:visible}.spark rect{fill:var(--tick)}.spark rect.bad{fill:var(--bad)}.spark rect.warn{fill:var(--warn)}.spark rect.running{fill:none;stroke:var(--ink);stroke-width:1}
.runs td{padding-top:11px;padding-bottom:11px}.runs tr.has-detail td{border-bottom:0;padding-bottom:4px}.runs tr.detail td{padding-top:0}
.metrics{display:flex;flex-wrap:wrap;gap:2px 14px}.metrics .k{color:var(--muted)}
pre{margin:6px 0 0;padding:12px 14px;background:var(--sunk);border:1px solid var(--rule);border-radius:3px;font:400 12.5px/1.55 var(--mono);color:var(--body);white-space:pre-wrap;overflow-wrap:anywhere;max-height:340px;overflow:auto}
details.out{margin-top:4px}details.out>summary{cursor:pointer;font:400 12px/1.6 var(--mono);color:var(--muted)}details.out>summary:hover{color:var(--ink)}
details.out.error>summary{color:var(--bad)}
dl.def{display:grid;grid-template-columns:max-content minmax(0,1fr);gap:8px 28px;margin:0}
dl.def dt{font:500 11px/1.9 var(--mono);letter-spacing:.08em;text-transform:uppercase;color:var(--muted)}
dl.def dd{margin:0;font:400 13.5px/1.7 var(--mono);color:var(--body);overflow-wrap:anywhere}dl.def dd.prose{font:400 16px/1.55 var(--serif)}
.empty{padding:28px 0 8px;color:var(--muted);max-width:60ch}
.empty code{font-size:.86em;color:var(--ink)}
.message{padding:clamp(56px,12vh,120px) 0;text-align:center}
.message h1{margin:0;font:400 clamp(28px,4vw,40px)/1.15 var(--serif);letter-spacing:-.015em}
.message p{margin:14px auto 0;max-width:52ch;color:var(--muted);text-wrap:pretty}
.signin{display:flex;flex-wrap:wrap;align-items:center;justify-content:center;gap:8px;margin:28px auto 0;max-width:420px}
.signin label{font:500 11px/1.4 var(--mono);letter-spacing:.08em;text-transform:uppercase;color:var(--muted)}
.signin input{flex:1 1 180px;min-width:0;font:400 16px/1.2 var(--mono);color:var(--ink);background:var(--sheet);border:1px solid var(--rule-2);border-radius:3px;height:32px;padding:0 10px}
footer{display:flex;flex-wrap:wrap;gap:6px 18px;padding:20px 0 40px;border-top:1px solid var(--rule);font:400 12px/1.5 var(--mono);color:var(--muted)}footer .version{margin-left:auto}
.timeline{margin:18px 0 0}
.timeline .axis,.timeline .under,.timeline .over,.timeline .lane{display:grid;grid-template-columns:var(--who) minmax(0,1fr)}
.timeline .hours{position:relative;height:22px;font:400 11px/1 var(--mono);color:var(--muted);letter-spacing:.04em}
.timeline .hours span{position:absolute;top:2px;transform:translateX(-50%);white-space:nowrap}
.timeline .hours .nowlabel{color:var(--ink);font-weight:500;animation:cw-fade .5s 1s both}
.timeline .field{position:relative}
.timeline .under,.timeline .over{position:absolute;inset:0;pointer-events:none}
.timeline .under>div,.timeline .over>div{position:relative}
.timeline .gl{position:absolute;top:0;bottom:0;width:1px;background:var(--rule)}
.timeline .future{position:absolute;top:0;bottom:0;right:0;background:var(--sunk)}
.timeline .now{position:absolute;top:-6px;bottom:0;width:1.5px;margin-left:-.75px;background:var(--ink);transform-origin:top;animation:cw-drop .6s .85s cubic-bezier(.2,.8,.2,1) both}
.timeline .lanes{position:relative;list-style:none;margin:0;padding:0;border-top:1px solid var(--rule);border-bottom:1px solid var(--rule)}
.timeline .lane{align-items:center;min-height:40px}
.timeline .who{display:grid;grid-template-columns:auto minmax(0,1fr);align-items:center;column-gap:0;padding:6px 14px 6px 0;min-width:0}
.timeline .who .sched{grid-column:2}
.timeline.week .who{display:flex;align-items:baseline;gap:10px}
.timeline .who .name{font:500 13px/1.35 var(--mono);color:var(--ink);overflow-wrap:anywhere}
.timeline .who .sched{font:400 11px/1.35 var(--mono);color:var(--muted);white-space:nowrap}
.timeline .track{position:relative;height:24px}
.timeline .marks{display:block;width:100%;height:24px;overflow:visible}
.timeline .note{position:absolute;top:50%;transform:translateY(-50%);font:italic 400 14px/1.2 var(--serif);color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;padding:0 3px;text-shadow:0 0 3px var(--sheet),0 0 3px var(--sheet),0 0 6px var(--sheet);animation:cw-fade .6s 1.1s both}
.timeline .note.before{text-align:right}
.timeline .legend{display:flex;flex-wrap:wrap;gap:6px 18px;margin:14px 0 0;padding-left:var(--who);font:400 11.5px/1.4 var(--mono);color:var(--muted)}
.timeline .legend span{display:inline-flex;align-items:center;gap:7px}
.timeline .more{margin:10px 0 0;padding-left:var(--who);font-size:14px;color:var(--muted);font-style:italic}
.key{width:16px;height:12px;overflow:visible}
.marks *{vector-effect:non-scaling-stroke}
svg .base{stroke:var(--rule);stroke-width:1}
svg .tick{stroke:var(--tick);stroke-width:1.5}svg .tick.ahead{stroke-dasharray:2 2;opacity:.75}
svg .cadence{stroke:var(--tick);stroke-width:2;stroke-dasharray:1 3}
svg .run{stroke-width:2;stroke-linejoin:round}
svg .run.ok{fill:var(--ok);stroke:var(--ok)}
svg .run.bad{fill:var(--bad);stroke:var(--bad)}
svg .run.timeout{fill:var(--bad);fill-opacity:.28;stroke:var(--bad);stroke-width:1.5}
svg .run.warn{fill:var(--warn);stroke:var(--warn)}
svg .run.running{fill:none;stroke:var(--ink);stroke-width:1.5}
svg .run.stuck{fill:var(--bad);fill-opacity:.12;stroke:var(--bad);stroke-width:1.5}
svg .missed{fill:none;stroke:var(--bad);stroke-width:1.5;stroke-dasharray:3 2.5}
svg .unloaded{fill:var(--sunk)}
svg .ahead{fill:var(--sunk)}
svg .nowline{stroke:var(--ink);stroke-width:1.5}
.marks .tick{animation:cw-fade .4s var(--d,0ms) both}
.marks .run,.marks .missed{transform-box:fill-box;transform-origin:0 50%;animation:cw-grow .55s cubic-bezier(.2,.8,.2,1) var(--d,0ms) both}
.marks .missed,.marks .run.running,.marks .run.stuck{animation:cw-grow .55s cubic-bezier(.2,.8,.2,1) var(--d,0ms) both,cw-breathe 2.6s ease-in-out calc(var(--d,0ms) + .6s) infinite alternate}
.figures>div{animation:cw-rise .5s cubic-bezier(.2,.8,.2,1) both}
.figures>div:nth-child(2){animation-delay:40ms}.figures>div:nth-child(3){animation-delay:80ms}.figures>div:nth-child(4){animation-delay:120ms}.figures>div:nth-child(5){animation-delay:160ms}.figures>div:nth-child(6){animation-delay:200ms}
@keyframes cw-fade{from{opacity:0}}
@keyframes cw-grow{from{opacity:0;transform:scaleX(0)}}
@keyframes cw-drop{from{opacity:0;transform:scaleY(0)}}
@keyframes cw-rise{from{opacity:0;transform:translateY(4px)}}
@keyframes cw-breathe{to{opacity:.38}}
body{padding:0 env(safe-area-inset-right) 0 env(safe-area-inset-left)}
footer{padding-bottom:calc(40px + env(safe-area-inset-bottom))}
@media(display-mode:standalone){
.top{position:sticky;top:0;z-index:2;background:var(--sheet);padding-top:calc(14px + env(safe-area-inset-top));padding-bottom:13px;-webkit-user-select:none;user-select:none}
.message{padding-top:clamp(40px,8vh,80px)}
}
@media(prefers-reduced-motion:reduce){*,*::before,*::after{animation:none!important;transition:none!important}}
@media(max-width:760px){
.sec{grid-template-columns:minmax(0,1fr);gap:10px;padding:24px 0}
.hide-sm{display:none}
:root{--who:0px}
.timeline .lane{grid-template-columns:minmax(0,1fr);padding:6px 0 8px}
.timeline .who{padding:0 0 4px}
.timeline .who .name{background:var(--sheet);padding-right:4px}
.timeline .hours .minor,.timeline .hours .near{display:none}
.timeline .note{font-size:13px}
td.job{min-width:0}
table.board thead{display:none}
table.board tr{display:grid;grid-template-columns:minmax(0,1fr) auto;column-gap:14px;padding:12px 0;border-bottom:1px solid var(--rule)}
table.board tbody tr:last-child{border-bottom:0}
table.board td{border:0;padding:0}
table.board td.last{grid-column:1/-1;margin-top:4px;white-space:normal}
table.board td.last .sub{display:inline;margin-left:8px}
.runs td.nowrap{white-space:normal}
dl.def{grid-template-columns:minmax(0,1fr);gap:0}dl.def dd{margin-bottom:10px}
}
`

// dashboardMark is the clock face from cronwatch.dev, in the text colour.
const dashboardMark = `<svg viewBox="0 0 40 40" aria-hidden="true" focusable="false"><rect x="1" y="1" width="38" height="38" rx="9.5" fill="none" stroke="currentColor" stroke-opacity=".22" stroke-width="1.5"/><circle cx="20" cy="20" r="10.5" fill="none" stroke="currentColor" stroke-width="2"/><path d="M20 12.5V20h6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>`

// appJS registers the service worker, and switches between light and dark
// on Cmd+Shift+D (Ctrl+Shift+D elsewhere), keeping the choice in
// localStorage. The page works the same without it. Its own URL gives the base, so it is the same
// text wherever the dashboard is mounted.
const appJS = `"use strict";
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
`

// swJS is the service worker. It caches the app shell (the offline page,
// the manifest, the icons, and app.js) and nothing else: every other request
// goes to the network as the page made it, and its answer is never stored,
// since the pages and the JSON carry job data. When a page cannot be
// reached it shows the offline page. Its scope gives the base, so it is the
// same text wherever the dashboard is mounted.
const swJS = `"use strict";
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
`
