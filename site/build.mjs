/**
 * Builds cronwatch.dev into dist/: the landing page from src/landing.html,
 * one page per markdown file in docs/, and hashed copies of the assets. The
 * landing page quotes real library output captured into src/demo by
 * scripts/demo.mjs --capture; a one-off build fails without those captures.
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
const PAGES = path.join(here, "pages");
const DEMO = path.join(SRC, "demo");
const DIST = path.join(here, "dist");
const SITE = "https://cronwatch.dev";
const GITHUB = "https://github.com/phillips-jon/cronwatch";
/**
 * Maven has no version range an install line can use, so the Java install
 * lines name the release: {{JAVA_VERSION}} in the landing page, the prompt
 * and the docs is the parent POM's <revision>, which scripts/release.mjs bumps.
 */
const JAVA_VERSION = /<revision>([^<]+)<\/revision>/.exec(readFileSync(path.join(here, "..", "packages", "java", "pom.xml"), "utf8"))[1];
const versioned = (text) => text.replace(/\{\{JAVA_VERSION\}\}/g, () => JAVA_VERSION);
const args = process.argv.slice(2);
const WATCHING = args.includes("--watch") || args.includes("--serve");

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
  const m = /^---\r?\n([\s\S]*?)\r?\n---(?:\r?\n)?/.exec(text);
  if (!m) return { meta: {}, body: text };
  const meta = {};
  for (const line of m[1].split(/\r?\n/)) {
    const i = line.indexOf(":");
    if (i > 0) meta[line.slice(0, i).trim()] = line.slice(i + 1).trim().replace(/^"|"$/g, "");
  }
  return { meta, body: text.slice(m[0].length) };
}

/**
 * Minimal, safe syntax colouring for TypeScript, Ruby, shell, YAML and JSON blocks.
 * Strings and comments are found in one left-to-right pass, so a // or # inside
 * a string (a URL, say) stays part of the string. A comment marker only counts
 * at the start of a line or after whitespace: // in code, # in Ruby, shell and YAML.
 * Ruby also gets its keywords, symbols (:name, and name: as a key) in the
 * string colour, and constants (Cronwatch::ActiveJob) in ink.
 */
const STRING = /&quot;(?:[^&]|&(?!quot;))*?&quot;|&#39;[^\n]*?&#39;|'[^'\n]*'|`[^`]*`/.source;
const COMMENT = { code: /(?<=^|\s)\/\/[^\n]*/.source, shell: /(?<=^|\s)#(?![{!])[^\n]*/.source };
const RUBY = new RegExp([
  /\b(alias|and|begin|break|case|class|def|defined\?|do|else|elsif|end|ensure|extend|false|for|if|in|include|module|next|nil|not|or|prepend|private|protected|public|raise|redo|require|require_relative|rescue|retry|return|self|super|then|true|undef|unless|until|when|while|yield)(?![\w?!:])/.source,
  /((?<![\w:]):[A-Za-z_]\w*[?!]?|\b[a-z_]\w*[?!]?:(?=\s))/.source,
  /(\b[A-Z]\w*)/.source,
].join("|"), "g");
function highlight(code, lang) {
  const esc = escape(code);
  if (!["ts", "tsx", "js", "typescript", "javascript", "json", "bash", "sh", "shell", "yaml", "yml", "ruby", "rb"].includes(lang)) return esc;
  const tokens = [];
  const stash = (html) => `\u0000${tokens.push(html) - 1}\u0000`;
  const ruby = lang === "ruby" || lang === "rb";
  const shell = ruby || lang.startsWith("sh") || lang === "bash" || lang.startsWith("y");
  const lexer = new RegExp(`(${shell ? COMMENT.shell : COMMENT.code})|${STRING}`, "gm");
  let out = esc.replace(lexer, (m, c) => stash(`<span class="${c ? "c" : "s"}">${m}</span>`));
  out = ruby
    ? out.replace(RUBY, (m, k, s) => `<span class="${k ? "k" : s ? "s" : "n"}">${m}</span>`)
    : out.replace(/\b(import|export|from|const|let|var|async|await|return|function|new|if|else|throw|try|catch|finally|type|interface|extends|default|for|of|in|while|null|true|false|undefined)\b/g, '<span class="k">$1</span>');
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
  // A wide table scrolls inside its own box rather than widening the page.
  table(token) {
    return `<div class="table">${new marked.Renderer().table.call(this, token)}</div>\n`;
  },
};
marked.use({ renderer, gfm: true });

/** Typographic apostrophes in prose, leaving code and attributes alone. */
function curlyApostrophes(html) {
  return html.split(/(<pre[\s\S]*?<\/pre>|<code[\s\S]*?<\/code>|<[^>]+>)/).map((part, i) => (i % 2 === 1 ? part : part.replace(/(\w)(?:'|&#39;)(\w)/g, "$1’$2"))).join("");
}

/* The mark: a clock at three, the hour the invoice run failed, in a rounded box. */
// The clock in a rounded box, as in the favicon; the box itself is CSS (.brand .mark).
const MARK = `<span class="mark" aria-hidden="true"><svg viewBox="0 0 40 40" focusable="false"><circle cx="20" cy="20" r="10.5" fill="none" stroke="currentColor" stroke-width="2"/><path d="M20 12.5V20h6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg></span>`;

const assets = { css: "", js: "", theme: "", search: "", index: "" };

/* The browser chrome matches --paper; theme.js and site.js swap it to the
   dark paper when the sheet is turned over. */
const THEME_COLOR = "#09090b";

function layout({ title, description, body, path: pagePath, kind = "page", index = true, head = "" }) {
  const canonical = `${SITE}${pagePath}`;
  const fullTitle = pagePath === "/" ? "CronWatch | Cron fails silently. This doesn’t." : `${title} | CronWatch`;
  const here = (href) => (href === pagePath || (href === "/docs/" && pagePath.startsWith("/docs/")) ? "here" : "");
  const links = LINKS.map((l) => {
    const cls = [l.cta ? "cta" : "", here(l.href)].filter(Boolean).join(" ");
    return `<a href="${l.href}"${cls ? ` class="${cls}"` : ""}>${escape(l.label)}</a>`;
  }).join("");
  return `<!doctype html>
<html lang="en" data-theme="dark">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escape(fullTitle)}</title>
<meta name="description" content="${escape(description)}">
${index ? `<link rel="canonical" href="${canonical}">` : `<meta name="robots" content="noindex">`}
${head ? `${head}\n` : ""}<meta property="og:title" content="${escape(fullTitle)}">
<meta property="og:description" content="${escape(description)}">
${index ? `<meta property="og:url" content="${canonical}">\n` : ""}<meta property="og:type" content="website">
<meta name="theme-color" content="${THEME_COLOR}">
<link rel="icon" href="/assets/favicon.svg" type="image/svg+xml">
<link rel="stylesheet" href="https://use.typekit.net/gie6nes.css">
<script src="${assets.theme}"></script>
<link rel="stylesheet" href="${assets.css}">
<script src="${assets.js}" defer></script>
<script src="${assets.search}" data-index="${assets.index}" defer></script>
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
    <nav aria-label="Project links"><a href="/docs/">Docs</a><a href="${GITHUB}">GitHub</a><a href="https://www.npmjs.com/package/@cronwatch/sdk">npm</a><a href="https://rubygems.org/gems/cronwatch">RubyGems</a><a href="https://pypi.org/project/cronwatch-sdk/">PyPI</a><a href="https://packagist.org/packages/cronwatch/cronwatch">Packagist</a><a href="https://pkg.go.dev/cronwatch.dev/go">pkg.go.dev</a><a href="https://crates.io/crates/cronwatch">crates.io</a><a href="https://hex.pm/packages/cronwatch">Hex</a><a href="https://central.sonatype.com/artifact/dev.cronwatch/cronwatch">Maven Central</a><button class="theme" type="button" title="Turn the paper over (Shift+Cmd+D, or Shift+Ctrl+D)" aria-label="Switch between light and dark">Dark paper</button></nav>
    <nav class="legal" aria-label="Site policies"><a href="/terms/">Terms</a><a href="/privacy/">Privacy</a><a href="/contact/">Contact</a></nav>
    <p class="rights">© ${new Date().getFullYear()} CronWatch. MIT licensed. Made by <a href="https://joncphillips.com" rel="me">Jon Phillips</a>.</p>
  </footer>
</div>
</body>
</html>
`;
}

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

const hhmm = (t) => new Date(t).toISOString().slice(11, 16);
const f1 = (n) => n.toFixed(1);
const need = (re, text, what) => {
  const m = re.exec(text);
  if (!m) throw new Error(`dashboard.html has no ${what}`);
  return m;
};

/**
 * The dashboard page as cw.routes() served it for the demo jobs, taken
 * apart: the hour labels, grid and now line of its last-24-hours timeline,
 * each lane's marks and note, its legend, and the rows of its jobs table.
 * The landing page redraws these under its own stylesheet, because its CSP
 * allows no style attributes and the dashboard places things with them.
 */
function readDashboard() {
  const html = readFileSync(path.join(DEMO, "dashboard.html"), "utf8");
  const figure = need(/<figure class="timeline day">([\s\S]*?)<\/figure>/, html, "day timeline")[1];
  const hours = need(/<div class="hours">([\s\S]*?)<\/div><\/div>/, figure, "hour labels")[1];
  const labels = [...hours.matchAll(/<span class="([^"]*)" style="left:([\d.]+)%">([^<]*)<\/span>/g)].map((m) => ({ cls: m[1], at: Number(m[2]), text: m[3] }));
  const grid = [...figure.matchAll(/<i class="gl" style="left:([\d.]+)%"><\/i>/g)].map((m) => Number(m[1]));
  const now = Number(need(/<i class="now" style="left:([\d.]+)%">/, figure, "now line")[1]);
  const lanes = [...figure.matchAll(/<li class="lane">([\s\S]*?)<\/li>/g)].map(([, lane]) => {
    const note = /<span class="note( before)?" style="(?:left|right):([\d.]+)%;max-width:([\d.]+)%">([^<]*)<\/span>/.exec(lane);
    return {
      tone: need(/<i class="sq (\w+)"/, lane, "lane state")[1],
      name: need(/class="name"[^>]*>([\s\S]*?)<\/a>/, lane, "lane name")[1].replace(/<wbr>/g, ""),
      sched: need(/<span class="sched">([^<]*)</, lane, "lane schedule")[1],
      marks: need(/<svg class="marks"[^>]*>([\s\S]*?)<\/svg>/, lane, "lane marks")[1],
      note: note ? { before: Boolean(note[1]), at: note[1] ? 100 - Number(note[2]) : Number(note[2]), room: Number(note[3]), text: note[4] } : null,
    };
  });
  return {
    clock: need(/<span class="meta">([^<]*)</, html, "clock")[1],
    lede: need(/aria-label="Last 24 hours">[\s\S]*?<p class="lede">([^<]*)</, html, "timeline lede")[1],
    labels, grid, now, lanes,
    legend: need(/<p class="legend"[\s\S]*?<\/p>/, figure, "legend")[0],
    words: need(/<ul class="vh">[\s\S]*?<\/ul>/, figure, "lane words")[0],
    boardHead: need(/<table class="board">\s*<thead>([\s\S]*?)<\/thead>/, html, "board header")[1],
    // Job names link to job pages that exist only inside an app.
    boardRows: need(/<tbody>([\s\S]*?)<\/tbody>/, html, "board rows")[1].replace(/<a class="name" href="[^"]*">([\s\S]*?)<\/a>/g, '<span class="name">$1</span>'),
  };
}

/**
 * A lane's marks, as the dashboard drew them in its 1000-unit lane, with each
 * animation delay moved from a style attribute to a class (d0 to d24).
 */
function marks(svg) {
  return svg.replace(/ style="--d:(\d+)ms"/g, (m, ms) => ` data-d="${Math.min(24, Math.round(Number(ms) / 40))}"`)
    .replace(/class="([^"]*)"([^>]*?) data-d="(\d+)"/g, 'class="$1 d$3"$2');
}

/** A note cut to fit the room the dashboard gave it, at about `em` units a letter. */
function fit(text, room, em) {
  const plain = text.replace(/&#39;/g, "'").replace(/&amp;/g, "&");
  const max = Math.floor(room / em);
  return escape(plain.length > max ? `${plain.slice(0, Math.max(1, max - 1)).trimEnd()}…` : plain);
}

/**
 * The dashboard's last-24-hours timeline as one SVG: hour labels across the
 * top, a lane per job with its name and schedule, the marks exactly as the
 * dashboard placed them, the notes, and the now line. `narrow` sets each
 * job's name above its lane, for a phone.
 */
function timelineSvg(d, narrow) {
  const W = narrow ? 360 : 1080, L = narrow ? 0 : 210, TW = W - L;
  const AX = 24, LANE = narrow ? 58 : 42, TRACK = narrow ? 34 : LANE / 2;
  const H = AX + d.lanes.length * LANE;
  const px = (pct) => L + (pct / 100) * TW;
  const nowX = px(d.now);
  let s = `<svg class="tl ${narrow ? "narrow" : "wide"}" viewBox="0 0 ${W} ${H + 2}" aria-hidden="true" focusable="false">`;
  s += `<rect class="future" x="${f1(nowX)}" y="${AX}" width="${f1(W - nowX)}" height="${H - AX}"/>`;
  for (const g of d.grid) s += `<line class="gl" x1="${f1(px(g))}" y1="${AX}" x2="${f1(px(g))}" y2="${H}"/>`;
  s += `<line class="edge" x1="0" y1="${AX}" x2="${W}" y2="${AX}"/><line class="edge" x1="0" y1="${H}" x2="${W}" y2="${H}"/>`;
  const nowLabel = d.labels.find((l) => l.cls === "nowlabel");
  for (const l of d.labels) {
    if (l.cls === "nowlabel") continue;
    if (narrow && (l.cls === "minor" || Math.abs(px(l.at) - nowX) < 64 || px(l.at) < 18)) continue;
    s += `<text class="hour${l.cls ? ` ${l.cls}` : ""}" x="${f1(px(l.at))}" y="15">${l.text}</text>`;
  }
  if (nowLabel) {
    const right = nowX > W - 50;
    s += `<text class="hour nowlabel" x="${f1(right ? nowX + 4 : nowX)}" y="15"${right ? ' text-anchor="end"' : ""}>${nowLabel.text}</text>`;
  }
  d.lanes.forEach((lane, i) => {
    const top = AX + i * LANE;
    const mid = narrow ? top + 16 + TRACK / 2 : top + LANE / 2;
    if (narrow) {
      s += `<rect class="sq ${lane.tone}" x="0.5" y="${top + 7.5}" width="7" height="7" rx="1.5"/>`;
      s += `<text class="name" x="14" y="${top + 15}">${lane.name}<tspan class="sched" dx="8">${lane.sched}</tspan></text>`;
    } else {
      s += `<rect class="sq ${lane.tone}" x="0.5" y="${f1(mid - 11)}" width="7" height="7" rx="1.5"/>`;
      s += `<text class="name" x="15" y="${f1(mid - 3)}">${lane.name}</text>`;
      s += `<text class="sched" x="15" y="${f1(mid + 11)}">${lane.sched}</text>`;
    }
    s += `<g class="marks" transform="translate(${L} ${f1(mid - 12)}) scale(${(TW / 1000).toFixed(4)} 1)">${marks(lane.marks)}</g>`;
    if (lane.note) {
      const x = px(lane.note.at);
      const room = (lane.note.room / 100) * TW;
      s += `<text class="note" x="${f1(x)}" y="${f1(mid + 4.5)}"${lane.note.before ? ' text-anchor="end"' : ""}>${fit(lane.note.text, room, narrow ? 6.2 : 6.9)}</text>`;
    }
  });
  s += `<line class="now" x1="${f1(nowX)}" y1="${AX - 6}" x2="${f1(nowX)}" y2="${H}"/>`;
  return `${s}</svg>`;
}

/** The mark from the dashboard's header. */
const DASH_MARK = `<svg class="dmark" viewBox="0 0 40 40" aria-hidden="true" focusable="false"><rect x="1" y="1" width="38" height="38" rx="9.5" fill="none" stroke="currentColor" stroke-opacity=".22" stroke-width="1.5"/><circle cx="20" cy="20" r="10.5" fill="none" stroke="currentColor" stroke-width="2"/><path d="M20 12.5V20h6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>`;

/** A flat browser window around a page from inside an app. */
function browser(inner, label) {
  return `<figure class="browser" aria-label="${escape(label)}"><div class="chrome" aria-hidden="true"><span class="dots"><i></i><i></i><i></i></span><span class="url">yourapp.com/cronwatch</span><span></span></div><div class="screen">${inner}</div></figure>`;
}

const HEALTH_ORDER = [["failing", "bad"], ["stuck", "bad"], ["late", "warn"], ["healthy", "ok"], ["silenced", "muted"], ["never_ran", "muted"]];

/** The dashboard's health row, counted from the captured jobs. */
function healthRow(jobs) {
  const attention = jobs.filter((j) => j.health !== "healthy").length;
  const figures = HEALTH_ORDER.map(([health, cls]) => {
    const n = jobs.filter((j) => j.health === health).length;
    return `<div class="${n === 0 ? "zero" : cls}"><dt><i class="sq ${cls}" aria-hidden="true"></i>${health.replace("_", " ")}</dt><dd>${n}</dd></div>`;
  }).join("");
  return `<p class="headline">${jobs.length} jobs, <b>${attention} needing attention</b>.</p><dl class="figures">${figures}</dl>`;
}

function dashTop(clock) {
  return `<div class="dtop"><p class="dbrand">${DASH_MARK}<span>CronWatch</span></p><p class="dact"><span class="meta">${escape(clock)}</span><span class="fake" aria-hidden="true">Run check now</span></p></div>`;
}

/* ---- Concept illustrations. Not recorded output, and labelled as such. ---- */

/**
 * How each check decides, on one clock. A playhead sweeps left to right; each
 * mark arrives as it passes, so the missed alert fires when the grace window
 * runs out, the stuck alert when the run passes its timeout, and the budget
 * alert on the run that costs three times the usual. `narrow` stacks each
 * lane's label above it.
 */
function checksSvg(narrow) {
  const W = narrow ? 360 : 1000, L = narrow ? 0 : 170, TW = W - L;
  const x = (t) => L + t * TW;
  const lanes = [
    { key: "missed", title: "Missed", sub: "due, then nothing within the grace", h: 56 },
    { key: "stuck", title: "Stuck", sub: "started, never finished", h: 56 },
    { key: "budget", title: "Over budget", sub: "cost three times the usual", h: 112 },
  ];
  const HEAD = narrow ? 24 : 0, GAP = narrow ? 22 : 30, TOP = 18;
  let y = TOP;
  const tops = lanes.map((l) => { const t = y + HEAD; y = t + l.h + GAP; return t; });
  const H = y - GAP + 16;
  // Delay classes p0 to p20: the playhead passes t = n / 20.
  const at = (t) => `p${Math.round(t * 20)}`;
  let s = `<svg class="ill ${narrow ? "narrow" : "wide"}" viewBox="0 0 ${W} ${H}" role="img" aria-labelledby="ill-${narrow ? "n" : "w"}"><title id="ill-${narrow ? "n" : "w"}">Illustration: a job due with nothing run by the end of its grace window raises missed; a run that passes its timeout raises stuck; a run that costs three times its usual raises over budget.</title>`;
  lanes.forEach((l, i) => {
    const top = tops[i], mid = top + (l.key === "budget" ? l.h - 12 : l.h / 2);
    if (narrow) {
      s += `<text class="lt" x="0" y="${top - 10}">${l.title}<tspan class="ls" dx="8">${l.sub}</tspan></text>`;
    } else {
      s += `<text class="lt" x="0" y="${mid - 3}">${l.title}</text><text class="ls" x="0" y="${mid + 13}">${l.sub}</text>`;
    }
    s += `<line class="base" x1="${L}" y1="${mid}" x2="${W}" y2="${mid}"/>`;
    const tick = (t, label) => `<line class="tick ${at(t)}" x1="${f1(x(t))}" y1="${mid - 7}" x2="${f1(x(t))}" y2="${mid + 7}"/>${label ? `<text class="cap ${at(t)}" x="${f1(x(t))}" y="${mid + 22}">${label}</text>` : ""}`;
    const bar = (t0, t1, cls) => `<rect class="bar ${cls} ${at(t0)}" x="${f1(x(t0))}" y="${mid - 7}" width="${f1(x(t1) - x(t0))}" height="14" rx="1.5"/>`;
    const alert = (t, text, tone, right = true) => `<g class="alert ${tone} ${at(t)}"><line x1="${f1(x(t))}" y1="${mid - 20}" x2="${f1(x(t))}" y2="${mid - 9}"/><circle cx="${f1(x(t))}" cy="${mid - 22}" r="2.5"/><text x="${f1(x(t) + (right ? 7 : -7))}" y="${mid - 18.5}"${right ? "" : ' text-anchor="end"'}>${text}</text></g>`;
    if (l.key === "missed") {
      s += tick(0.08) + bar(0.08, 0.1, "ok") + tick(0.34) + bar(0.34, 0.36, "ok") + tick(0.6, "due");
      s += `<rect class="grace grow ${at(0.6)}" x="${f1(x(0.6))}" y="${mid - 12}" width="${f1(x(0.78) - x(0.6))}" height="24"/>`;
      s += `<text class="cap ${at(0.6)}" x="${f1((x(0.6) + x(0.78)) / 2)}" y="${mid - 16}">grace</text>`;
      s += `<rect class="missed ${at(0.78)}" x="${f1(x(0.6))}" y="${mid - 7}" width="${f1(x(0.78) - x(0.6))}" height="14" rx="1.5"/>`;
      s += alert(0.78, narrow ? "missed" : "missed alert", "bad");
      s += tick(0.86) + `<text class="cap ${at(0.86)}" x="${f1(x(0.86))}" y="${mid + 22}">still nothing</text>`;
    } else if (l.key === "stuck") {
      s += tick(0.12, "started") + `<rect class="bar running grow slow ${at(0.12)}" x="${f1(x(0.12))}" y="${mid - 7}" width="${f1(x(0.52) - x(0.12))}" height="14" rx="1.5"/>`;
      s += `<line class="limit ${at(0.12)}" x1="${f1(x(0.52))}" y1="${mid - 13}" x2="${f1(x(0.52))}" y2="${mid + 13}"/><text class="cap ${at(0.12)}" x="${f1(x(0.52))}" y="${mid + 25}">timeout</text>`;
      s += `<rect class="bar stuck grow slower ${at(0.52)}" x="${f1(x(0.52))}" y="${mid - 7}" width="${f1(x(1) - x(0.52))}" height="14" rx="1.5"/>`;
      s += alert(0.56, narrow ? "stuck" : "stuck alert", "bad");
    } else {
      const base = mid, unit = 2.4;
      const usual = 10, ceiling = 3 * usual;
      const runs = [[0.08, 10], [0.23, 11], [0.38, 9], [0.53, 10], [0.68, 11], [0.84, 34]];
      s += `<line class="usual" x1="${L}" y1="${f1(base - usual * unit)}" x2="${W}" y2="${f1(base - usual * unit)}"/><text class="cap" x="${W}" y="${f1(base - usual * unit - 5)}" text-anchor="end">usual</text>`;
      s += `<line class="limit" x1="${L}" y1="${f1(base - ceiling * unit)}" x2="${W}" y2="${f1(base - ceiling * unit)}"/><text class="cap" x="${W}" y="${f1(base - ceiling * unit - 5)}" text-anchor="end">ceiling</text>`;
      for (const [t, cost] of runs) {
        const over = cost > ceiling, hgt = cost * unit;
        s += `<rect class="cost ${over ? "warn" : "ok"} ${at(t)}" x="${f1(x(t) - 6)}" y="${f1(base - hgt)}" width="12" height="${f1(hgt)}" rx="1.5"/>`;
      }
      s += `<g class="alert warn ${at(0.84)}"><text x="${f1(x(0.84) + 6)}" y="${f1(base - 34 * unit - 8)}" text-anchor="end">${narrow ? "over budget" : "over budget alert"}</text></g>`;
    }
  });
  // The playhead: where "now" is. Drawn at the end when nothing moves.
  s += `<g class="head"><line x1="${f1(x(1))}" y1="4" x2="${f1(x(1))}" y2="${H - 8}"/></g>`;
  return `${s}</svg>`;
}

/**
 * Where the records go, as a flat diagram: a hosted monitor, where your app
 * sends pings and output to their servers and they alert you, against
 * CronWatch, where the library in your app writes to your own database and
 * alerts you itself.
 */
function versusSvg(which) {
  const W = 400, H = 214;
  const box = (x, y, w, h, label, sub, cls = "") => `<rect class="node${cls ? ` ${cls}` : ""}" x="${x}" y="${y}" width="${w}" height="${h}" rx="3"/><text class="nl" x="${x + w / 2}" y="${y + h / 2 + (sub ? -3 : 5)}">${label}</text>${sub ? `<text class="ns" x="${x + w / 2}" y="${y + h / 2 + 14}">${sub}</text>` : ""}`;
  const arrow = (x1, y1, x2, y2, label, lx, ly, anchor = "middle") => `<line class="flow" x1="${x1}" y1="${y1}" x2="${x2}" y2="${y2}" marker-end="url(#${which}-head)"/>${label ? `<text class="fl" x="${lx}" y="${ly}" text-anchor="${anchor}">${label}</text>` : ""}`;
  let s = `<svg class="versus-svg" viewBox="0 0 ${W} ${H}" aria-hidden="true" focusable="false"><defs><marker id="${which}-head" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="8" markerHeight="8" orient="auto-start-reverse"><path class="headp" d="M1 1L7 4L1 7"/></marker></defs>`;
  if (which === "hosted") {
    s += box(8, 20, 130, 58, "Your app", "runs the jobs");
    s += box(262, 20, 130, 58, "Their servers", "a paid account", "theirs");
    s += box(262, 150, 130, 48, "You", "");
    s += arrow(140, 40, 258, 40, "pings", 199, 32);
    s += arrow(140, 60, 258, 60, "job output", 199, 76);
    s += arrow(327, 80, 327, 146, "alert", 334, 118, "start");
  } else {
    s += `<rect class="node" x="8" y="12" width="150" height="100" rx="3"/><text class="nl" x="83" y="36">Your app</text>`;
    s += box(22, 52, 122, 44, "CronWatch", "", "lib");
    s += `<rect class="node" x="262" y="36" width="130" height="76" rx="3"/><text class="nl" x="327" y="62">Your database</text><text class="ns" x="327" y="81">SQLite, Postgres,</text><text class="ns" x="327" y="97">MySQL, D1</text>`;
    s += box(18, 150, 130, 48, "You", "");
    s += arrow(146, 74, 258, 74, "runs, output", 202, 66);
    s += arrow(83, 114, 83, 146, "alert", 90, 134, "start");
  }
  return `${s}</svg>`;
}

/** The captured demo output, rendered for the landing page. */
function demoContent() {
  const out = { MCP_LIST_JOBS: "", ALERT_MISSED: "", ALERT_BUDGET: "", ALERT_FAILED: "", ALERT_RECOVERED: "", T_FAILED: "", FAILED_CRON: "", FAILED_AT: "", FAILED_RAN: "", T_MISSED: "", T_BUDGET: "", T_RECOVERED: "", RUNS_FRAME: "", BOARD_FRAME: "", CHECKS_ILL: "", VERSUS: "" };
  try {
    const { capturedAt, jobs } = JSON.parse(readFileSync(path.join(DEMO, "jobs.json"), "utf8"));
    const dash = readDashboard();
    const alerts = readFileSync(path.join(DEMO, "alerts.txt"), "utf8").split(/\n\n+/).map((a) => a.trim()).filter(Boolean);

    out.RUNS_FRAME = browser(`${dashTop(dash.clock)}
<div class="dsec"><p class="dlabel">Health</p><div>${healthRow(jobs)}</div></div>
<div class="dsec"><p class="dlabel">Last 24 hours</p><p class="lede">${dash.lede}</p>
<div class="dwide play-on-view"><div class="tlbox">${timelineSvg(dash, false)}${timelineSvg(dash, true)}</div>${dash.legend}${dash.words}</div></div>`, "The CronWatch dashboard: health and the last 24 hours");

    const counts = HEALTH_ORDER.map(([health, cls]) => [health, cls, jobs.filter((j) => j.health === health).length]).filter(([, , n]) => n > 0)
      .map(([health, cls, n]) => `<span class="state ${cls}"><i class="sq ${cls}" aria-hidden="true"></i>${n} ${health.replace("_", " ")}</span>`).join("");
    out.BOARD_FRAME = browser(`${dashTop(dash.clock)}
<div class="dsec"><p class="dlabel">Jobs</p><div><p class="counts">${counts}</p></div>
<div class="dwide"><table class="board"><thead>${dash.boardHead}</thead><tbody>${dash.boardRows}</tbody></table></div></div>`, "The CronWatch dashboard: the jobs table");

    out.CHECKS_ILL = `${checksSvg(false)}${checksSvg(true)}`;
    out.VERSUS = `<figure class="vs"><figcaption>A hosted monitor</figcaption>${versusSvg("hosted")}</figure><figure class="vs"><figcaption>CronWatch</figcaption>${versusSvg("cw")}</figure>`;

    const mcp = JSON.parse(readFileSync(path.join(DEMO, "mcp.json"), "utf8"));
    out.MCP_LIST_JOBS = colourReply(mcp.find((x) => x.tool === "list_jobs")?.reply ?? "");

    out.ALERT_MISSED = alertBlock(alerts, "sync-crm missed");
    out.ALERT_BUDGET = alertBlock(alerts, "daily-digest went over budget");
    out.ALERT_RECOVERED = alertBlock(alerts, "invoice-run recovered");
    out.ALERT_FAILED = alertBlock(alerts, "invoice-run failed");
    out.T_FAILED = alertTime(alerts, "invoice-run failed");
    // The plain cron pane on the left of the failure pair: the job's own
    // schedule, the second it started and how long it ran, all as captured.
    out.FAILED_CRON = escape(jobs.find((j) => j.name === "invoice-run")?.definition.schedule ?? "");
    const failed = alerts.find((x) => x.includes("invoice-run failed")) ?? "";
    out.FAILED_AT = /Started \S+ (\d{2}:\d{2}:\d{2}) UTC/.exec(failed)?.[1] ?? "";
    out.FAILED_RAN = escape(/, ran ([^.\s]+)\./.exec(failed)?.[1] ?? "");
    // The missed alert went out at the check the capture ran, just past its deadline.
    out.T_MISSED = `${hhmm(capturedAt)} UTC`;
    out.T_BUDGET = alertTime(alerts, "daily-digest went over budget");
    out.T_RECOVERED = alertTime(alerts, "invoice-run recovered");
    const empty = Object.keys(out).filter((k) => !out[k]);
    if (empty.length) throw new Error(`nothing captured for ${empty.join(", ")}`);
  } catch (e) {
    // Without the captures the landing page would ship empty. While watching,
    // keep serving so the rest of the site can be worked on.
    const message = `demo captures missing or unreadable (run site/scripts/demo.mjs --capture): ${e.message}`;
    if (!WATCHING) throw new Error(message);
    console.warn(message);
  }
  return out;
}

/* ---- Terms, privacy and the contact form. ---- */

/** A page with its mono label down the left, the way the landing sets a section. */
function solo(label, inner) {
  return `<div class="solo"><p class="label">${escape(label)}</p><article class="doc">${inner}</article></div>`;
}

/**
 * The contact form. It posts to /contact, which nginx hands to
 * deploy/contact/server.mjs; the service answers with a redirect to
 * /contact/sent/ or /contact/error/, so it works without script. site.js
 * fills `t` with how long the page was open before sending, measured in the
 * browser; the service turns away anything sent in under three seconds.
 * `website` is a trap for bots and stays empty for people.
 */
const CONTACT_FORM = `<form class="contact" method="post" action="/contact">
<p class="field"><label for="c-name">Name</label><input id="c-name" name="name" type="text" required maxlength="200" autocomplete="name"></p>
<p class="field"><label for="c-email">Email</label><input id="c-email" name="email" type="email" required maxlength="320" autocomplete="email" spellcheck="false"></p>
<p class="field"><label for="c-message">Message</label><textarea id="c-message" name="message" required maxlength="5000" rows="8"></textarea></p>
<p class="vh" aria-hidden="true"><label for="c-website">Leave this empty</label><input id="c-website" name="website" type="text" tabindex="-1" autocomplete="off"></p>
<input type="hidden" name="t" value="">
<p><button class="prompt-btn" type="submit">Send</button></p>
</form>`;

const CONTACT_INTRO = `<h1>Contact</h1>
<p>Write here with a question, a bug report, or a request to delete something you sent. A human reads every message and replies to the address you give.</p>
<p>Bugs and feature requests are often quicker as <a href="${GITHUB}/issues">GitHub issues</a>, which are public. What you send here is used only to reply to you; the <a href="/privacy/">privacy page</a> says what happens to it.</p>`;

/** Terms and privacy from pages/*.md, and the contact page with its two answers. */
function buildPages() {
  const write = (route, page) => {
    const dir = path.join(DIST, route);
    mkdirSync(dir, { recursive: true });
    writeFileSync(path.join(dir, "index.html"), layout({ path: route, kind: "page", ...page }));
  };
  const indexed = [];
  for (const file of readdirSync(PAGES).filter((f) => f.endsWith(".md")).sort()) {
    const { meta, body } = frontmatter(readFileSync(path.join(PAGES, file), "utf8"));
    const route = `/${file.replace(/\.md$/, "")}/`;
    const updated = meta.updated ? `<p class="updated">Last updated ${escape(meta.updated)}</p>` : "";
    const html = curlyApostrophes(marked.parse(body)).replace(/(<\/h1>\n)/, `$1${updated}`);
    write(route, { title: meta.title, description: meta.description ?? "", body: solo(meta.label ?? meta.title, html) });
    indexed.push(route);
  }

  write("/contact/", {
    title: "Contact", description: "Send a message to the maintainer of CronWatch.",
    body: solo("Contact", `${CONTACT_INTRO}${CONTACT_FORM}`),
  });
  indexed.push("/contact/");
  write("/contact/sent/", {
    title: "Message sent", description: "Your message was sent.", index: false,
    body: solo("Contact", `<h1>Sent</h1>
<p class="notice ok" role="status">Thank you. Your message is on its way, and the reply will come to the email address you gave.</p>
<p><a href="/">Back to the start</a></p>`),
  });
  write("/contact/error/", {
    title: "Message not sent", description: "Your message was not sent.", index: false,
    body: solo("Contact", `<h1>Not sent</h1>
<p class="notice bad" role="alert">Your message did not go through, so nothing was sent. Check that each field is filled in and the email address is complete, then try again. If it keeps failing, wait a minute, or open an issue on <a href="${GITHUB}/issues">GitHub</a>.</p>
${CONTACT_FORM}`),
  });
  return { indexed, count: indexed.length + 2 };
}

/* ---- The Go module's import paths. ---- */

/**
 * The Go port's import path is cronwatch.dev/go (packages/go/DESIGN.md), so
 * the go command, and the module proxy for it, asks this site where the code
 * is: for `go get cronwatch.dev/go/river` it fetches /go/river?go-get=1 and
 * reads the go-import tag there. Every module and every package a user
 * imports has a page, each carrying its module's tag and a line or two for a
 * person who follows the path in a browser. nginx serves them as directories
 * whatever the query (deploy/nginx.conf).
 *
 * A tag's last field is Go 1.25's subdirectory. The go command puts the part
 * of a module path past the tag's prefix in front of that subdirectory
 * (modfetch.newCodeRepo), so a nested module under the core's tag would be
 * looked for in river/packages/go. Each nested module's pages therefore
 * name the module's own path and directory, and its tags are
 * packages/go/<name>/vX.Y.Z, the go command's rule for a module below a
 * repository's root.
 */
const GO_SRC = `${GITHUB}/tree/main`;
const GO_MODULES = [
  {
    path: "cronwatch.dev/go", dir: "packages/go", docs: "/docs/go/",
    what: "The Go port of CronWatch, package <code>cronwatch</code>: jobs, runs and checks, the memory store, the dashboard and job handlers as <code>http.Handler</code>s, with no requirements of its own.",
    packages: [
      { name: "sqlstore", docs: "/docs/go/#stores", what: "The <code>database/sql</code> store: SQLite, Postgres and MySQL over the app's own <code>*sql.DB</code> and driver." },
      { name: "alerts", docs: "/docs/go/#alerts", what: "The alert channels: Slack, Discord, a signed webhook, email, SMS and error trackers, on <code>net/http</code> alone." },
      { name: "triage", docs: "/docs/go/#triage", what: "Claude triage of each alert, over plain HTTP." },
      { name: "pgcron", docs: "/docs/go/#pg-cron", what: "The pg_cron source: pg_cron's jobs and runs read through the app's <code>*sql.DB</code>." },
      { name: "storetest", docs: "/docs/go/#stores", what: "The store contract test, for a store of your own." },
      { name: "bridge", docs: "/docs/go-schedulers/", what: "What the scheduler integrations share. Most apps never import it." },
    ],
  },
  { path: "cronwatch.dev/go/robfigcron", dir: "packages/go/robfigcron", docs: "/docs/go-schedulers/#robfig-cron", what: "Watches a robfig/cron v3 scheduler: one option to <code>cron.New</code>." },
  { path: "cronwatch.dev/go/gocron", dir: "packages/go/gocron", docs: "/docs/go-schedulers/#gocron", what: "Watches a go-co-op/gocron v2 scheduler: one option to <code>gocron.NewScheduler</code>." },
  { path: "cronwatch.dev/go/river", dir: "packages/go/river", docs: "/docs/go-schedulers/#river", what: "Watches River's periodic jobs and workers: a periodic job constructor and a worker middleware." },
  { path: "cronwatch.dev/go/asynq", dir: "packages/go/asynq", docs: "/docs/go-schedulers/#asynq", what: "Watches Asynq's scheduler and server: a scheduler that declares its entries and a server middleware." },
];

/** A description as the second half of a list item: "sqlstore: the database/sql store". */
const lowerFirst = (t) => (/^Claude\b/.test(t) ? t : t[0].toLowerCase() + t.slice(1));

/** The go-import and go-source tags for a module. */
function goMeta(mod) {
  const src = `${GO_SRC}/${mod.dir}`;
  return `<meta name="go-import" content="${mod.path} git ${GITHUB} ${mod.dir}">
<meta name="go-source" content="${mod.path} ${src} ${src}{/dir} ${GITHUB}/blob/main/${mod.dir}{/dir}/{file}#L{line}">`;
}

/** One page per module and per package in it, under /go/. */
function buildGoPages() {
  let count = 0;
  const write = (mod, importPath, heading, intro, extra = "") => {
    const route = `/${importPath.replace(/^cronwatch\.dev\//, "")}/`;
    const dir = path.join(DIST, route);
    mkdirSync(dir, { recursive: true });
    const parent = importPath === mod.path ? "" : `<p>A package of the module <a href="/${mod.path.replace(/^cronwatch\.dev\//, "")}/"><code>${mod.path}</code></a>, released with it.</p>`;
    // A break after each slash, so a long path wraps on a phone.
    const inner = `<h1><code translate="no">${importPath.replace(/\//g, "/<wbr>")}</code></h1>
<p>${intro}</p>${parent}
<div class="code"><pre><code translate="no">go get ${importPath}</code></pre></div>
<p><a href="${heading.docs}">Read the docs</a>, the <a href="https://pkg.go.dev/${importPath}">reference on pkg.go.dev</a>, or <a href="${GO_SRC}/${mod.dir}${importPath === mod.path ? "" : `/${importPath.slice(mod.path.length + 1)}`}">the source</a>.</p>${extra}`;
    writeFileSync(path.join(dir, "index.html"), layout({
      title: importPath, description: `The Go import path ${importPath}, for go get.`,
      path: route, kind: "page", index: false, head: goMeta(mod),
      body: solo("Go", inner),
    }));
    count++;
  };
  for (const mod of GO_MODULES) {
    const list = mod.packages
      ? `<h2>Packages</h2><ul>${mod.packages.map((p) => `<li><a href="/go/${p.name}/"><code>${mod.path}/${p.name}</code></a>: ${lowerFirst(p.what)}</li>`).join("")}</ul>
<h2>Scheduler integrations</h2><p>Modules of their own, so an app pulls only the scheduler it uses.</p><ul>${GO_MODULES.filter((m) => !m.packages).map((m) => `<li><a href="/${m.path.replace(/^cronwatch\.dev\//, "")}/"><code>${m.path}</code></a>: ${lowerFirst(m.what)}</li>`).join("")}</ul>`
      : "";
    write(mod, mod.path, mod, mod.what, list);
    for (const p of mod.packages ?? []) write(mod, `${mod.path}/${p.name}`, p, p.what);
  }
  return count;
}

/* ---- Docs search. ---- */

/**
 * The search entry at the top of the docs sidebar and the phone's docs menu.
 * Without script it is a link to the docs index; search.js turns it into a
 * button that opens the search dialog, and fills in the shortcut it shows.
 */
const SEARCH_OPEN = `<a class="search-open" href="/docs/" data-search-open><span>Search docs</span><kbd></kbd></a>`;

const ENTITIES = { amp: "&", lt: "<", gt: ">", quot: '"', "#39": "'", nbsp: " " };
/** Rendered HTML to one line of plain text, code blocks left out. */
function plain(html) {
  return html
    .replace(/<div class="code">[\s\S]*?<\/div>/g, " ")
    .replace(/<[^>]+>/g, " ")
    .replace(/&(#\d+|#x[0-9a-f]+|\w+);/gi, (m, e) => ENTITIES[e] ?? (e[0] === "#" ? String.fromCodePoint(e[1] === "x" || e[1] === "X" ? parseInt(e.slice(2), 16) : Number(e.slice(1))) : m))
    .replace(/\s+/g, " ")
    .replace(/ ([.,;:)])/g, "$1")
    .replace(/\( /g, "(")
    .trim();
}

/** Cut at a word boundary near `max` characters. */
function clip(text, max = 300) {
  if (text.length <= max) return text;
  const cut = text.slice(0, max);
  return `${cut.slice(0, Math.max(cut.lastIndexOf(" "), max - 40)).replace(/[\s,;:.]+$/, "")}…`;
}

/**
 * The search index: for each docs page, its title, route and group, then one
 * entry per section, [heading, anchor, excerpt], starting with the text
 * before the first heading (with an empty heading and anchor). Taken from
 * the rendered HTML, so every anchor is the id the page really has.
 */
function searchIndex(pages) {
  return pages.map((p) => {
    const parts = p.html.split(/<h([23]) id="([^"]*)">([\s\S]*?)<\/h\1>/);
    const sections = [["", "", clip(plain(parts[0].replace(/<h1[\s\S]*?<\/h1>/, "")))]];
    for (let i = 1; i < parts.length; i += 4) sections.push([plain(parts[i + 2]), parts[i + 1], clip(plain(parts[i + 3]))]);
    return { t: p.meta.title, u: p.route, g: p.meta.group || "", s: sections };
  });
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
  const theme = readFileSync(path.join(SRC, "theme.js"), "utf8");
  assets.theme = `/assets/theme.${hash(theme)}.js`;
  writeFileSync(path.join(DIST, assets.theme), theme);

  const pages = readdirSync(DOCS).filter((f) => f.endsWith(".md")).map((file) => {
    const { meta, body } = frontmatter(versioned(readFileSync(path.join(DOCS, file), "utf8")));
    const name = file.replace(/\.md$/, "");
    const route = name === "index" ? "/docs/" : `/docs/${name}/`;
    return { name, route, meta, html: curlyApostrophes(marked.parse(body)), order: Number(meta.order ?? 999) };
  }).sort((a, b) => a.order - b.order || a.name.localeCompare(b.name));

  // The docs search index is a script, not JSON: the CSP's connect-src is
  // 'none', so search.js cannot fetch it, but script-src 'self' lets it add
  // a script tag the first time the search opens.
  const index = `window.cronwatchSearch=${JSON.stringify(searchIndex(pages))};\n`;
  assets.index = `/assets/search-index.${hash(index)}.js`;
  writeFileSync(path.join(DIST, assets.index), index);
  const search = readFileSync(path.join(SRC, "search.js"), "utf8");
  assets.search = `/assets/search.${hash(search)}.js`;
  writeFileSync(path.join(DIST, assets.search), search);

  // Replacer functions, so a $& or $1 in captured text is inserted as written.
  let landing = versioned(readFileSync(path.join(SRC, "landing.html"), "utf8")).replace(/\{\{GITHUB\}\}/g, () => GITHUB);
  const promptHtml = escape(versioned(readFileSync(path.join(SRC, "prompt.txt"), "utf8")));
  landing = landing.replace(/\{\{PROMPT\}\}/g, () => promptHtml);
  for (const [key, value] of Object.entries(demoContent())) landing = landing.replace(new RegExp(`\\{\\{${key}\\}\\}`, "g"), () => value);
  writeFileSync(path.join(DIST, "index.html"), layout({
    title: "CronWatch",
    description: "Cron monitoring as a library for TypeScript, Ruby, Python, PHP, Go, Rust, Elixir and Java. Every run recorded in your own database, and an alert when one is missed, fails or gets stuck.",
    body: landing,
    path: "/",
    kind: "landing",
  }));

  // Pages that share a frontmatter `group` are listed under its name. Give
  // them neighbouring `order` values, or the group is started twice.
  const docList = (here) => {
    let html = "", open = null;
    for (const [i, p] of pages.entries()) {
      const group = p.meta.group || null;
      if (group !== open) {
        if (open) html += "</ol></li>";
        if (group) html += `<li class="group"><p>${escape(group)}</p><ol>`;
        open = group;
      }
      html += `<li><a href="${p.route}"${p.route === here ? ' class="here" aria-current="page"' : ""}><span>${String(i + 1).padStart(2, "0")}</span><span>${escape(p.meta.title)}</span></a></li>`;
    }
    return `<ol>${html}${open ? "</ol></li>" : ""}</ol>`;
  };

  for (const [i, page] of pages.entries()) {
    const html = page.html;
    const prev = pages[i - 1], next = pages[i + 1];
    const pager = `<nav class="pager" aria-label="Previous and next">${prev ? `<a class="prev" href="${prev.route}"><small>Previous</small>${escape(prev.meta.title)}</a>` : "<span></span>"}${next ? `<a class="next" href="${next.route}"><small>Next</small>${escape(next.meta.title)}</a>` : ""}</nav>`;
    const body = `<div class="docs"><aside class="docs-side" aria-label="Documentation">${SEARCH_OPEN}<div class="docs-scroll"><p>Documentation</p>${docList(page.route)}</div></aside><details class="docs-menu"><summary>Documentation</summary>${SEARCH_OPEN}${docList(page.route)}</details><article class="doc"><p class="label">${escape(page.meta.title)}</p>${html}${pager}</article></div>`;
    const dir = path.join(DIST, page.route);
    mkdirSync(dir, { recursive: true });
    writeFileSync(path.join(dir, "index.html"), layout({ title: page.meta.title, description: page.meta.description ?? "", body, path: page.route, kind: "docs" }));
  }

  // The 50x page serves 500, 502, 503 and 504 alike, so it shows no code.
  const lost = (code, heading, line, note) => `
<section class="lost">
${code ? `  <p class="code" aria-hidden="true">${code}</p>\n` : ""}  <h1>${heading}</h1>
  <p class="line">${line}</p>
  <div class="actions"><a class="prompt-btn" href="/">Go to the start</a><a class="ghost-btn" href="/docs/">Read the docs</a></div>
  <p class="note">${note}</p>
</section>`;
  writeFileSync(path.join(DIST, "404.html"), layout({
    title: "Not found", description: "That page is not here.", path: "/404", kind: "docs", index: false,
    body: lost("404", "That page is not here", "The address may be old, or it may have a typo in it.", `If a link on this site sent you here, <a href="/contact/">tell us</a>, or <a href="${GITHUB}/issues">open an issue on GitHub</a>.`),
  }));
  writeFileSync(path.join(DIST, "50x.html"), layout({
    title: "Something went wrong", description: "The server hit an error.", path: "/50x", kind: "docs", index: false,
    body: lost(null, "Something went wrong", "The server hit an error on its end, or is briefly unavailable. Try again in a minute.", `If it keeps happening, <a href="${GITHUB}/issues">tell us on GitHub</a>.`),
  }));

  const extra = buildPages();
  const goPages = buildGoPages();

  const prompt = versioned(readFileSync(path.join(SRC, "prompt.txt"), "utf8"));
  writeFileSync(path.join(DIST, "prompt.txt"), prompt);
  writeFileSync(path.join(DIST, "llms.txt"), `# CronWatch\n\n> Open source cron and scheduled-job monitoring as a library: @cronwatch/sdk for TypeScript (Node, Cloudflare Workers, Deno, Bun), the cronwatch gem for Ruby and Rails, cronwatch-sdk for Python (Django, Celery, APScheduler), cronwatch/cronwatch for PHP (Laravel, Symfony, WordPress, Drupal, Craft CMS), cronwatch.dev/go for Go (robfig/cron, gocron, River, Asynq), the cronwatch crate for Rust (tokio-cron-scheduler, apalis), the cronwatch package on Hex for Elixir (Oban, Quantum), and dev.cronwatch:cronwatch on Maven Central for Java (Spring Boot, Quartz, JobRunr). Runs inside your app, writes to your own database, alerts when a run is missed, fails, gets stuck, runs slow or goes over budget.\n\nPlatforms: Vercel cron, Next.js, SvelteKit, Nuxt, React Router, NestJS, Strapi, Netlify, Firebase, Convex, Trigger.dev, Inngest, Cloudflare Workers with D1, pg_cron and Supabase Cron, node-cron, BullMQ, GitHub Actions, Rails with ActiveJob, Solid Queue or Sidekiq, Django, Celery and beat, APScheduler, AWS Lambda, Laravel's scheduler and queues, the Symfony Scheduler and Messenger, WordPress's WP-Cron, Drupal cron and queues, Craft CMS console commands and queue jobs, Go's robfig/cron, gocron, River and Asynq, Rust's tokio-cron-scheduler and apalis, Elixir's Oban and Quantum, Java's Spring @Scheduled methods (with ShedLock), Quartz and JobRunr.\n\nSetup instructions for an agent: ${SITE}/prompt.txt\nDocs: ${SITE}/docs/\nRails docs: ${SITE}/docs/rails/\nPython docs: ${SITE}/docs/python/, ${SITE}/docs/django/, ${SITE}/docs/celery/\nPHP docs: ${SITE}/docs/php/, ${SITE}/docs/laravel/, ${SITE}/docs/symfony/, ${SITE}/docs/wordpress/, ${SITE}/docs/drupal/, ${SITE}/docs/craft/\nGo docs: ${SITE}/docs/go/, ${SITE}/docs/go-schedulers/\nRust docs: ${SITE}/docs/rust/, ${SITE}/docs/rust-schedulers/\nElixir docs: ${SITE}/docs/elixir/, ${SITE}/docs/elixir-schedulers/\nJava docs: ${SITE}/docs/java/, ${SITE}/docs/java-schedulers/\nnpm: npm install @cronwatch/sdk\nRubyGems: bundle add cronwatch\nPyPI: pip install cronwatch-sdk\nPackagist: composer require cronwatch/cronwatch\nGo: go get cronwatch.dev/go\ncrates.io: cargo add cronwatch\nHex: {:cronwatch, \"~> 0.8\"} in mix.exs\nMaven Central: dev.cronwatch:cronwatch:${JAVA_VERSION}, or dev.cronwatch:cronwatch-spring-boot-starter:${JAVA_VERSION} in a Spring Boot app\nWordPress plugin (not in the wordpress.org directory yet): https://github.com/phillips-jon/cronwatch/releases/latest/download/cronwatch.zip, installed with wp plugin install <that url> --activate or uploaded in wp-admin\nMCP server: npx -y @cronwatch/mcp\nMCP docs: ${SITE}/docs/mcp/\n`);

  const urls = ["/", ...pages.map((p) => p.route), ...extra.indexed];
  writeFileSync(path.join(DIST, "sitemap.xml"), `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls.map((u) => `  <url><loc>${SITE}${u}</loc></url>`).join("\n")}\n</urlset>\n`);
  writeFileSync(path.join(DIST, "robots.txt"), `User-agent: *\nAllow: /\nSitemap: ${SITE}/sitemap.xml\n`);

  console.log(`built ${pages.length + 2 + extra.count + goPages} pages -> ${path.relative(process.cwd(), DIST) || "."}`);
}

build();

if (WATCHING) {
  let timer = null;
  const rebuild = () => {
    clearTimeout(timer);
    timer = setTimeout(() => {
      try { build(); } catch (e) { console.error(e); }
    }, 80);
  };
  for (const dir of [SRC, DOCS, PAGES]) watch(dir, { recursive: true }, rebuild);
  console.log("watching src/, docs/ and pages/");
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
