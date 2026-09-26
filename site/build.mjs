/**
 * Builds cronwatch.dev into dist/: the landing page from src/landing.html,
 * one page per markdown file in docs/, and hashed copies of the assets. The
 * landing page quotes real library output captured into src/demo by
 * scripts/demo.mjs --capture.
 *
 *   node build.mjs            build once
 *   node build.mjs --watch    rebuild on change
 *   node build.mjs --serve    build, watch, and serve on http://localhost:4321
 */
import { createHash } from "node:crypto";
import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, watch, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { marked } from "marked";

const here = path.dirname(fileURLToPath(import.meta.url));
const SRC = path.join(here, "src");
const DOCS = path.join(here, "docs");
const DEMO = path.join(SRC, "demo");
const DIST = path.join(here, "dist");
const SITE = "https://cronwatch.dev";
const GITHUB = "https://github.com/phillips-jon/cronwatch";

const escape = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
const slug = (s) => s.toLowerCase().replace(/<[^>]+>/g, "").replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
const hash = (buf) => createHash("sha256").update(buf).digest("hex").slice(0, 10);

const LINKS = [
  { label: "Docs", href: "/docs/" },
  { label: "MCP", href: "/docs/mcp/" },
  { label: "Agent Skill", href: "/docs/agent-skill/" },
  { label: "GitHub", href: GITHUB },
];

function frontmatter(text) {
  const m = /^---\n([\s\S]*?)\n---\n?/.exec(text);
  if (!m) return { meta: {}, body: text };
  const meta = {};
  for (const line of m[1].split("\n")) {
    const i = line.indexOf(":");
    if (i > 0) meta[line.slice(0, i).trim()] = line.slice(i + 1).trim().replace(/^"|"$/g, "");
  }
  return { meta, body: text.slice(m[0].length) };
}

/** Minimal, safe syntax colouring for TypeScript, shell and JSON blocks. */
function highlight(code, lang) {
  const esc = escape(code);
  if (!["ts", "tsx", "js", "typescript", "javascript", "json", "bash", "sh", "shell", "yaml", "yml"].includes(lang)) return esc;
  const tokens = [];
  const stash = (html) => `\u0000${tokens.push(html) - 1}\u0000`;
  const shell = lang.startsWith("sh") || lang === "bash" || lang.startsWith("y");
  let out = esc
    .replace(/(\/\/[^\n]*|#(?![{!])[^\n]*)/g, (m, c) => (shell || !c.startsWith("#") ? stash(`<span class="c">${c}</span>`) : c))
    .replace(/(&quot;(?:[^&]|&(?!quot;))*?&quot;|&#39;[^\n]*?&#39;|'[^'\n]*'|`[^`]*`)/g, (m) => stash(`<span class="s">${m}</span>`))
    .replace(/\b(import|export|from|const|let|var|async|await|return|function|new|if|else|throw|try|catch|finally|type|interface|extends|default|for|of|in|while|null|true|false|undefined)\b/g, '<span class="k">$1</span>');
  out = out.replace(/\u0000(\d+)\u0000/g, (m, i) => tokens[Number(i)]);
  return out;
}

const renderer = {
  heading({ tokens, depth }) {
    const text = this.parser.parseInline(tokens);
    const id = slug(text);
    return `<h${depth} id="${id}"><a class="anchor" href="#${id}">${text}</a></h${depth}>\n`;
  },
  code({ text, lang }) {
    const language = (lang || "").trim().split(/\s+/)[0] || "text";
    return `<div class="code"><pre><code translate="no">${highlight(text, language)}</code></pre></div>\n`;
  },
};
marked.use({ renderer, gfm: true });

/** Typographic apostrophes in prose, leaving code and attributes alone. */
function curlyApostrophes(html) {
  return html.split(/(<pre[\s\S]*?<\/pre>|<code[\s\S]*?<\/code>|<[^>]+>)/).map((part, i) => (i % 2 === 1 ? part : part.replace(/(\w)(?:'|&#39;)(\w)/g, "$1’$2"))).join("");
}

/* The mark: a clock at three, the hour the invoice run failed, in a rounded box. */
const MARK = `<svg class="mark" viewBox="0 0 40 40" aria-hidden="true" focusable="false"><rect x="0.5" y="0.5" width="39" height="39" rx="9.5" fill="var(--box)" stroke="var(--line)"/><circle cx="20" cy="20" r="10.5" fill="none" stroke="currentColor" stroke-width="2"/><path d="M20 12.5V20h6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>`;

const assets = { css: "", js: "" };

function layout({ title, description, body, path: pagePath, kind = "page" }) {
  const canonical = `${SITE}${pagePath}`;
  const fullTitle = pagePath === "/" ? "CronWatch | Cron fails silently. This doesn’t." : `${title} | CronWatch`;
  const here = (href) => (href === pagePath || (href === "/docs/" && pagePath.startsWith("/docs/")) ? "here" : "");
  const links = LINKS.map((l) => {
    const cls = [l.cta ? "cta" : "", here(l.href)].filter(Boolean).join(" ");
    return `<a href="${l.href}"${cls ? ` class="${cls}"` : ""}>${escape(l.label)}</a>`;
  }).join("");
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escape(fullTitle)}</title>
<meta name="description" content="${escape(description)}">
<link rel="canonical" href="${canonical}">
<meta property="og:title" content="${escape(fullTitle)}">
<meta property="og:description" content="${escape(description)}">
<meta property="og:url" content="${canonical}">
<meta property="og:type" content="website">
<meta name="theme-color" content="#efece2">
<link rel="icon" href="/assets/favicon.svg" type="image/svg+xml">
<link rel="preload" href="/assets/fonts/newsreader-normal-200-800.woff2" as="font" type="font/woff2" crossorigin>
<link rel="preload" href="/assets/fonts/plexmono-normal-400.woff2" as="font" type="font/woff2" crossorigin>
<link rel="stylesheet" href="${assets.css}">
<script src="${assets.js}" defer></script>
</head>
<body>
<a class="skip" href="#main">Skip to content</a>
<div class="page">
  <nav class="top" aria-label="Site">
    <div class="links">${links}</div>
    <details class="menu"><summary>Menu</summary><ol>${LINKS.map((l) => `<li><a href="${l.href}">${escape(l.label)}</a></li>`).join("")}</ol></details>
    <a class="brand" href="/" title="CronWatch">${MARK}<span translate="no">CronWatch</span></a>
  </nav>
  <main id="main">
${body}
  </main>
  <footer>
    <p>© ${new Date().getFullYear()} CronWatch. MIT. Made by <a href="https://joncphillips.com" rel="me">Jon Phillips</a>. Every alert, reply and mark here is real output from the library, for six sample jobs.</p>
    <nav aria-label="Project links"><a href="/docs/">Docs</a><a href="${GITHUB}">GitHub</a><a href="https://www.npmjs.com/package/@cronwatch/sdk">npm</a><button class="theme" type="button" title="Turn the paper over (Shift+Cmd+D)" aria-label="Switch between light and dark">Dark paper</button></nav>
  </footer>
</div>
</body>
</html>
`;
}

/** Formatting for the board and the strip, matching the library's own dashboard. */
const hhmm = (t) => new Date(t).toISOString().slice(11, 16);
function duration(ms) {
  if (ms == null) return "";
  if (ms < 1000) return `${ms}ms`;
  if (ms < 60_000) return `${Math.round(ms / 1000)}s`;
  const m = Math.floor(ms / 60_000), sec = Math.round((ms % 60_000) / 1000);
  return sec ? `${m}m ${sec}s` : `${m}m`;
}
const HEALTH = { healthy: "ok", late: "warn", failing: "bad", stuck: "bad", silenced: "muted", never_ran: "muted" };

/** Colour the health line of an MCP reply the way the board does. */
function colourReply(text) {
  return escape(text)
    .replace(/^(\d+ jobs?, \d+ needing attention\.)/m, "<b>$1</b>")
    .replace(/^(\S+): (failing|stuck)([^\n]*)/gm, '<b class="bad">$1: $2$3</b>')
    .replace(/^(\S+): (late)([^\n]*)/gm, '<b class="warn">$1: $2$3</b>');
}

/** One alert as printed: the title coloured by what it is, then the message. */
function alertBlock(alerts, needle) {
  const a = alerts.find((x) => x.includes(needle));
  if (!a) return "";
  const [first, ...rest] = a.split("\n");
  const tone = /failed|stuck/.test(first) ? "bad" : /recovered/.test(first) ? "ok" : "warn";
  return `<span class="t ${tone}">${escape(first)}</span>\n${escape(rest.join("\n"))}`;
}

/** The clock time an alert is about: the first time it mentions, or the nth. */
function alertTime(alerts, needle, which = 0) {
  const a = alerts.find((x) => x.includes(needle)) ?? "";
  const times = [...a.matchAll(/(\d{2}:\d{2}):\d{2} UTC/g)];
  return times[which] ? `${times[which][1]} UTC` : "";
}

/**
 * The day as an SVG. Hours across the top, one row per job. Every time a job
 * was *due* is a faint tick, so you can see the cadence it keeps; every run it
 * actually recorded is a solid mark on top. A dashed box is a slot that came
 * and went with nothing in it. The empty part of each row carries a note
 * saying what happened, which is the whole point of the picture.
 */
function strip() {
  const { capturedAt, dayStart, jobs } = JSON.parse(readFileSync(path.join(DEMO, "runs.json"), "utf8"));
  const DAY = 86_400_000, W = 1400, L = 196, R = 26, TOP = 40, ROW = 52, LEG = 58;
  const H = TOP + jobs.length * ROW + LEG;
  const x = (t) => L + ((t - dayStart) / DAY) * (W - L - R);
  const f = (n) => n.toFixed(1);
  const nx = x(capturedAt), late = nx > W - 170;

  /** What this row is worth saying out loud, anchored to the mark it is about. */
  function note(j) {
    const r = j.runs.length ? j.runs[j.runs.length - 1] : null;
    if (j.missedAt) return { at: j.missedAt, text: `due ${hhmm(j.missedAt)}, and nothing ran` };
    if (r && r.status === "failed") return { at: r.startedAt, text: `threw at ${hhmm(r.startedAt)}, and cron said nothing` };
    if (j.open.includes("over_budget")) return { at: r ? r.startedAt : null, text: "finished fine, and cost three times its usual" };
    if (r && r.status === "running") return { at: r.startedAt, text: `started ${hhmm(r.startedAt)}, still going` };
    return null;
  }

  let s = `<svg class="strip" viewBox="0 0 ${W} ${H}" role="img" aria-label="One day of scheduled runs for ${jobs.length} jobs: every time each job was due, and every run recorded">`;
  for (let h = 0; h <= 24; h += 2) {
    const gx = f(x(dayStart + h * 3_600_000));
    s += `<line class="grid" x1="${gx}" y1="${TOP}" x2="${gx}" y2="${TOP + jobs.length * ROW}"/>`;
    const clear = late ? gx > nx + 30 || gx < nx - 110 : gx < nx - 30 || gx > nx + 110;
    if (h < 24 && clear) s += `<text class="axis" x="${gx}" y="${TOP - 14}">${String(h).padStart(2, "0")}</text>`;
  }

  jobs.forEach((j, i) => {
    const cy = TOP + i * ROW + ROW / 2;
    s += `<text class="job" x="0" y="${cy - 1}">${escape(j.name)}</text>`;
    s += `<text class="sched" x="0" y="${cy + 14}">${escape(j.schedule)}</text>`;
    s += `<line class="base" x1="${L}" y1="${f(cy)}" x2="${W - R}" y2="${f(cy)}"/>`;

    for (const t of j.expected ?? []) {
      if (t < dayStart || t > dayStart + DAY) continue;
      s += `<line class="tick${t > capturedAt ? " ahead" : ""}" x1="${f(x(t))}" y1="${cy - 5}" x2="${f(x(t))}" y2="${cy + 5}"/>`;
    }

    for (const r of j.runs) {
      const end = r.finishedAt ?? capturedAt;
      const x1 = x(r.startedAt), x2 = Math.max(x(end), x1 + 4);
      const tone = r.status === "running" ? "running" : r.status !== "ok" ? "bad" : j.open.includes("over_budget") && r === j.runs[j.runs.length - 1] ? "warn" : "ok";
      const what = r.status === "running" ? `running since ${hhmm(r.startedAt)} UTC` : `${r.status} at ${hhmm(r.startedAt)} UTC, ${duration(r.durationMs)}`;
      s += `<rect class="run ${tone}" x="${f(x1)}" y="${cy - 7}" width="${f(x2 - x1)}" height="14" rx="2"><title>${escape(`${j.name}: ${what}`)}</title></rect>`;
    }
    if (j.missedAt) {
      s += `<rect class="run missed" x="${f(x(j.missedAt) - 5.5)}" y="${cy - 7}" width="11" height="14" rx="2"><title>${escape(`${j.name}: due ${hhmm(j.missedAt)} UTC, no run started`)}</title></rect>`;
    }

    // Put the note wherever this row is actually empty, so it never sits on
    // top of the marks it is describing.
    const n = note(j);
    if (n) {
      const spans = j.runs.map((r) => [x(r.startedAt), Math.max(x(r.finishedAt ?? capturedAt), x(r.startedAt) + 4)]);
      if (j.missedAt) spans.push([x(j.missedAt) - 6, x(j.missedAt) + 6]);
      const busyMin = spans.length ? Math.min(...spans.map((a) => a[0])) : nx;
      const busyMax = spans.length ? Math.max(...spans.map((a) => a[1])) : nx;
      const width = n.text.length * 6.1;
      const right = (W - R - busyMax) >= (busyMin - L);
      if (right ? W - R - busyMax > width + 40 : busyMin - L > width + 40) {
        const tx = right ? busyMax + 22 : busyMin - 22;
        s += `<text class="note" x="${f(tx)}" y="${f(cy + 4)}"${right ? "" : ' text-anchor="end"'}>${escape(n.text)}</text>`;
      }
    }
  });

  s += `<line class="now" x1="${f(nx)}" y1="${TOP - 6}" x2="${f(nx)}" y2="${TOP + jobs.length * ROW}"/>`;
  s += `<text class="axis now-label" x="${f(late ? nx - 8 : nx + 8)}" y="${TOP - 14}"${late ? ' text-anchor="end"' : ""}>now ${hhmm(capturedAt)} UTC</text>`;

  let lx = L;
  const ly = H - 14;
  s += `<line class="tick" x1="${lx + 1}" y1="${ly - 11}" x2="${lx + 1}" y2="${ly - 1}"/><text class="legend" x="${lx + 10}" y="${ly}">due</text>`;
  lx += 10 + 26 + 26;
  for (const [cls, label] of [["ok", "ran"], ["bad", "failed"], ["warn", "over budget"], ["missed", "never started"], ["running", "running now"]]) {
    s += `<rect class="run ${cls}" x="${lx}" y="${ly - 11}" width="15" height="12" rx="2"/><text class="legend" x="${lx + 22}" y="${ly}">${label}</text>`;
    lx += 22 + label.length * 6.9 + 28;
  }
  return s + "</svg>";
}

/** The captured demo output, rendered for the landing page. */
function demoContent() {
  const out = { BOARD_META: "", JOBS_BOARD: "", MCP_GET_JOB: "", MCP_LIST_JOBS: "", ALERT_MISSED: "", ALERT_BUDGET: "", ALERT_FAILED: "", ALERT_RECOVERED: "", T_FAILED: "", T_MISSED: "", T_BUDGET: "", T_RECOVERED: "", STRIP: "", DAY_META: "" };
  try {
    const { capturedAt, jobs } = JSON.parse(readFileSync(path.join(DEMO, "jobs.json"), "utf8"));
    const attention = jobs.filter((j) => j.health !== "healthy").length;
    out.BOARD_META = `${jobs.length} jobs, ${attention} needing attention<span class="sm"> · ${hhmm(capturedAt)} UTC</span>`;
    const rows = jobs.map((j) => {
      const r = j.lastRun;
      const last = !r ? "never" : r.status === "running" ? '<span class="state info">running</span>' : escape(`${r.status}, ${duration(r.durationMs)}`);
      const extras = j.open.filter((c) => !["missed", "failed", "stuck"].includes(c)).map((c) => `<span class="state warn">${escape(c.replace("_", " "))}</span>`).join("");
      return `<tr><td class="name">${escape(j.name)}</td><td class="mono sm">${escape(j.definition.schedule)}</td><td><span class="state ${HEALTH[j.health]}">${escape(j.health.replace("_", " "))}</span>${extras}</td><td class="mono${r?.status === "failed" ? " bad" : ""}">${last}</td><td class="mono sm">${hhmm(j.nextExpectedAt)}</td></tr>`;
    });
    out.JOBS_BOARD = `<div class="rows"><table><thead><tr><th>Job</th><th class="sm">Schedule</th><th>Health</th><th>Last run</th><th class="sm">Next due</th></tr></thead><tbody>${rows.join("")}</tbody></table></div>`;

    const day = JSON.parse(readFileSync(path.join(DEMO, "runs.json"), "utf8"));
    const total = day.jobs.reduce((n, j) => n + j.runs.length, 0);
    out.DAY_META = `${new Date(day.dayStart).toISOString().slice(0, 10)} · ${total} runs by ${hhmm(day.capturedAt)} UTC`;
    out.STRIP = strip();

    const mcp = JSON.parse(readFileSync(path.join(DEMO, "mcp.json"), "utf8"));
    const reply = (tool) => mcp.find((x) => x.tool === tool)?.reply ?? "";
    out.MCP_GET_JOB = colourReply(reply("get_job"));
    out.MCP_LIST_JOBS = colourReply(reply("list_jobs"));

    const alerts = readFileSync(path.join(DEMO, "alerts.txt"), "utf8").split(/\n\n+/).map((a) => a.trim()).filter(Boolean);
    out.ALERT_MISSED = alertBlock(alerts, "sync-crm missed");
    out.ALERT_BUDGET = alertBlock(alerts, "daily-digest went over budget");
    out.ALERT_RECOVERED = alertBlock(alerts, "invoice-run recovered");
    out.ALERT_FAILED = alertBlock(alerts, "invoice-run failed");
    out.T_FAILED = alertTime(alerts, "invoice-run failed");
    out.T_MISSED = alertTime(alerts, "sync-crm missed", 1);
    out.T_BUDGET = alertTime(alerts, "daily-digest went over budget");
    out.T_RECOVERED = alertTime(alerts, "invoice-run recovered");
  } catch (e) {
    console.warn("demo captures missing; run scripts/demo.mjs --capture", e.message);
  }
  return out;
}

function build() {
  rmSync(DIST, { recursive: true, force: true });
  mkdirSync(path.join(DIST, "assets"), { recursive: true });
  cpSync(path.join(SRC, "assets"), path.join(DIST, "assets"), { recursive: true });

  const css = readFileSync(path.join(SRC, "style.css"), "utf8");
  assets.css = `/assets/style.${hash(css)}.css`;
  writeFileSync(path.join(DIST, assets.css), css);
  const js = readFileSync(path.join(SRC, "site.js"), "utf8");
  assets.js = `/assets/site.${hash(js)}.js`;
  writeFileSync(path.join(DIST, assets.js), js);

  let landing = readFileSync(path.join(SRC, "landing.html"), "utf8").replace(/\{\{GITHUB\}\}/g, GITHUB);
  landing = landing.replace(/\{\{PROMPT\}\}/g, escape(readFileSync(path.join(SRC, "prompt.txt"), "utf8")));
  for (const [key, value] of Object.entries(demoContent())) landing = landing.replace(new RegExp(`\\{\\{${key}\\}\\}`, "g"), value);
  writeFileSync(path.join(DIST, "index.html"), layout({
    title: "CronWatch",
    description: "Open source cron and scheduled-job monitoring that lives inside your TypeScript app. Every run recorded in your own database; alerts when a run is missed, fails, gets stuck, runs slow or goes over budget. MCP server included. No server to run.",
    body: landing,
    path: "/",
    kind: "landing",
  }));

  const pages = readdirSync(DOCS).filter((f) => f.endsWith(".md")).map((file) => {
    const { meta, body } = frontmatter(readFileSync(path.join(DOCS, file), "utf8"));
    const name = file.replace(/\.md$/, "");
    const route = name === "index" ? "/docs/" : `/docs/${name}/`;
    return { name, route, meta, body, order: Number(meta.order ?? 999) };
  }).sort((a, b) => a.order - b.order || a.name.localeCompare(b.name));
  const docList = (here) => `<ol>${pages.map((p, i) => `<li><a href="${p.route}"${p.route === here ? ' class="here" aria-current="page"' : ""}><span>${String(i + 1).padStart(2, "0")}</span><span>${escape(p.meta.title)}</span></a></li>`).join("")}</ol>`;

  for (const [i, page] of pages.entries()) {
    const html = curlyApostrophes(marked.parse(page.body));
    const prev = pages[i - 1], next = pages[i + 1];
    const pager = `<nav class="pager" aria-label="Previous and next">${prev ? `<a class="prev" href="${prev.route}"><small>Previous</small>${escape(prev.meta.title)}</a>` : "<span></span>"}${next ? `<a class="next" href="${next.route}"><small>Next</small>${escape(next.meta.title)}</a>` : ""}</nav>`;
    const body = `<div class="docs"><aside class="docs-side" aria-label="Documentation"><p>Documentation</p>${docList(page.route)}</aside><details class="docs-menu"><summary>Documentation</summary>${docList(page.route)}</details><article class="doc"><p class="label">${escape(page.meta.title)}</p>${html}${pager}</article></div>`;
    const dir = path.join(DIST, page.route);
    mkdirSync(dir, { recursive: true });
    writeFileSync(path.join(dir, "index.html"), layout({ title: page.meta.title, description: page.meta.description ?? "", body, path: page.route, kind: "docs" }));
  }

  writeFileSync(path.join(DIST, "404.html"), layout({
    title: "Not found", description: "That page is not here.", path: "/404", kind: "docs",
    body: `<article class="doc"><h1>Not found</h1><p>Nothing is scheduled at this address. Try the <a href="/docs/">docs</a> or the <a href="/">front page</a>.</p></article>`,
  }));

  const prompt = readFileSync(path.join(SRC, "prompt.txt"), "utf8");
  writeFileSync(path.join(DIST, "prompt.txt"), prompt);
  writeFileSync(path.join(DIST, "llms.txt"), `# CronWatch\n\n> Open source cron and scheduled-job monitoring as a TypeScript library. Runs inside your app, writes to your own database, alerts when a run is missed, fails, gets stuck, runs slow or goes over budget.\n\nSetup instructions for an agent: ${SITE}/prompt.txt\nDocs: ${SITE}/docs/\nMCP server: npx -y @cronwatch/mcp\n`);

  const urls = ["/", ...pages.map((p) => p.route)];
  writeFileSync(path.join(DIST, "sitemap.xml"), `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls.map((u) => `  <url><loc>${SITE}${u}</loc></url>`).join("\n")}\n</urlset>\n`);
  writeFileSync(path.join(DIST, "robots.txt"), `User-agent: *\nAllow: /\nSitemap: ${SITE}/sitemap.xml\n`);

  console.log(`built ${pages.length + 2} pages -> ${path.relative(process.cwd(), DIST) || "."}`);
}

build();

const args = process.argv.slice(2);
if (args.includes("--watch") || args.includes("--serve")) {
  let timer = null;
  const rebuild = () => {
    clearTimeout(timer);
    timer = setTimeout(() => {
      try { build(); } catch (e) { console.error(e); }
    }, 80);
  };
  for (const dir of [SRC, DOCS]) watch(dir, { recursive: true }, rebuild);
  console.log("watching src/ and docs/");
}

if (args.includes("--serve")) {
  const port = Number(process.env.PORT || 4321);
  const types = { ".html": "text/html; charset=utf-8", ".css": "text/css", ".js": "text/javascript", ".svg": "image/svg+xml", ".png": "image/png", ".woff2": "font/woff2", ".xml": "application/xml", ".txt": "text/plain", ".json": "application/json" };
  createServer((req, res) => {
    const url = new URL(req.url, "http://localhost");
    const clean = path.normalize(decodeURIComponent(url.pathname)).replace(/^(\.\.[/\\])+/, "");
    const candidates = [clean, path.join(clean, "index.html"), `${clean.replace(/\/$/, "")}.html`].map((c) => path.join(DIST, c));
    const file = candidates.find((c) => c.startsWith(DIST) && existsSync(c) && statSync(c).isFile()) ?? path.join(DIST, "404.html");
    res.writeHead(file.endsWith("404.html") ? 404 : 200, { "content-type": types[path.extname(file)] ?? "application/octet-stream", "cache-control": "no-store" });
    res.end(readFileSync(file));
  }).listen(port, "127.0.0.1", () => console.log(`serving http://localhost:${port}`));
}
