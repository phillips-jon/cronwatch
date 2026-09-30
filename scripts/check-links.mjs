/**
 * Checks every internal link in the built site. Reads each HTML file under
 * the directory given (default site/dist), and fails when an href or src on
 * this site points at a file that was not built, or at a #fragment that no
 * id on the target page carries, or when a page carries one id twice. Links
 * to other origins are not fetched.
 *
 *   node scripts/check-links.mjs [site/dist]
 */
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import path from "node:path";

const DIST = path.resolve(process.argv[2] ?? "site/dist");
if (!existsSync(DIST)) {
  console.error(`check-links: ${DIST} does not exist; run npm run build:site first`);
  process.exit(1);
}

function walk(dir) {
  return readdirSync(dir).flatMap((name) => {
    const full = path.join(dir, name);
    return statSync(full).isDirectory() ? walk(full) : [full];
  });
}

const pages = walk(DIST).filter((f) => f.endsWith(".html"));
const idCache = new Map();

/** The ids on a built page, read once. */
function idsOf(file) {
  if (!idCache.has(file)) {
    const html = readFileSync(file, "utf8");
    idCache.set(file, new Set([...html.matchAll(/\sid="([^"]+)"/g)].map((m) => decodeEntities(m[1]))));
  }
  return idCache.get(file);
}

function decodeEntities(s) {
  return s.replace(/&amp;/g, "&").replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, "<").replace(/&gt;/g, ">");
}

/** The built file a site path is served from, or null. */
function resolveFile(urlPath) {
  const clean = decodeURIComponent(urlPath);
  const target = path.join(DIST, clean);
  if (!target.startsWith(DIST)) return null;
  if (clean.endsWith("/")) return existsSync(path.join(target, "index.html")) ? path.join(target, "index.html") : null;
  if (existsSync(target) && statSync(target).isFile()) return target;
  if (existsSync(path.join(target, "index.html"))) return path.join(target, "index.html");
  if (existsSync(`${target}.html`)) return `${target}.html`;
  return null;
}

const problems = [];
let checked = 0;
for (const page of pages) {
  const html = readFileSync(page, "utf8");
  const rel = `/${path.relative(DIST, page).split(path.sep).join("/")}`;
  // An id twice on a page sends a #fragment to the first of them, whichever
  // section the link meant.
  const seen = new Set();
  for (const m of html.matchAll(/\sid="([^"]+)"/g)) {
    const id = decodeEntities(m[1]);
    if (seen.has(id)) problems.push(`${rel}: the id "${id}" is on the page more than once`);
    seen.add(id);
  }
  const pageUrl = new URL(rel, "https://site.invalid");
  for (const m of html.matchAll(/\s(?:href|src)="([^"]*)"/g)) {
    const raw = decodeEntities(m[1]);
    if (raw === "" || /^(mailto:|tel:|javascript:|data:)/i.test(raw)) continue;
    const url = new URL(raw, pageUrl);
    if (url.origin !== pageUrl.origin) continue;
    checked++;
    const file = url.pathname === pageUrl.pathname ? page : resolveFile(url.pathname);
    if (!file) {
      problems.push(`${rel}: ${raw} (no such file)`);
      continue;
    }
    const fragment = decodeURIComponent(url.hash.slice(1));
    if (fragment && file.endsWith(".html") && !idsOf(file).has(fragment)) {
      problems.push(`${rel}: ${raw} (no id "${fragment}" on ${path.relative(DIST, file)})`);
    }
  }
}

if (problems.length > 0) {
  console.error(`check-links: ${problems.length} problem${problems.length === 1 ? "" : "s"} (broken links or repeated ids)`);
  for (const p of problems) console.error(`  ${p}`);
  process.exit(1);
}
console.log(`check-links: ${checked} links on ${pages.length} pages, all resolve`);
