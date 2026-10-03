#!/usr/bin/env node
/**
 * Tells search engines which pages of cronwatch.dev changed, through
 * IndexNow (Bing, Yandex, Seznam, Naver and others share submissions).
 *
 *   node site/scripts/indexnow.mjs <new dist> [<old dist>] [--dry-run]
 *
 * deploy/release-deploy runs it once a release is live, with the release
 * that was live before it. A page is submitted when its HTML differs from
 * the old release's, ignoring the content hashes in asset names (a style
 * change would otherwise resubmit every page). Without an old release, or
 * one that had no key file yet, every page in the sitemap is submitted.
 *
 * The key is the <32 hex>.txt file in the site's root (site/src/root),
 * which holds its own name; IndexNow fetches it to check a submission.
 * Only builtins: the release's node_modules is gone by the time this runs.
 */
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ENDPOINT = "https://api.indexnow.org/indexnow";

/** The key in a dist folder: a <32 hex>.txt in its root holding its own name. */
export function findKey(dist) {
  for (const name of readdirSync(dist)) {
    const m = /^([0-9a-f]{32})\.txt$/.exec(name);
    if (m && readFileSync(path.join(dist, name), "utf8").trim() === m[1]) return m[1];
  }
  return null;
}

/** The sitemap's URLs, in order. */
export function sitemapUrls(dist) {
  const xml = readFileSync(path.join(dist, "sitemap.xml"), "utf8");
  return [...xml.matchAll(/<loc>([^<]+)<\/loc>/g)].map((m) => m[1]);
}

/** The file nginx serves for a URL's path (try_files $uri $uri/index.html $uri.html). */
export function fileFor(dist, url) {
  const p = decodeURIComponent(new URL(url).pathname);
  const candidates = p.endsWith("/") ? [`${p}index.html`] : [p, `${p}/index.html`, `${p}.html`];
  for (const c of candidates) {
    const file = path.join(dist, c);
    if (statSync(file, { throwIfNoEntry: false })?.isFile()) return file;
  }
  return null;
}

/** A page's HTML without the content hashes in asset names. */
export const normalize = (html) => html.replace(/(\/assets\/[\w-]+)\.[0-9a-f]{10}\.(js|css)/g, "$1.$2");

/** The sitemap URLs of `dist` whose page differs from `old`'s (all of them without `old`). */
export function changedUrls(dist, old) {
  const urls = sitemapUrls(dist);
  if (!old || !existsSync(old) || !findKey(old)) return urls;
  return urls.filter((url) => {
    const now = fileFor(dist, url);
    const before = fileFor(old, url);
    if (!now || !before) return true;
    return normalize(readFileSync(now, "utf8")) !== normalize(readFileSync(before, "utf8"));
  });
}

export async function submit(urls, key, { fetch = globalThis.fetch } = {}) {
  const host = new URL(urls[0]).host;
  const res = await fetch(ENDPOINT, {
    method: "POST",
    headers: { "content-type": "application/json; charset=utf-8" },
    body: JSON.stringify({ host, key, keyLocation: `https://${host}/${key}.txt`, urlList: urls.slice(0, 10000) }),
    signal: AbortSignal.timeout(15_000),
  });
  return res.status;
}

async function main(argv) {
  const dryRun = argv.includes("--dry-run");
  const [dist, old] = argv.filter((a) => a !== "--dry-run");
  if (!dist) {
    console.error("Usage: indexnow.mjs <new dist> [<old dist>] [--dry-run]");
    return 64;
  }
  const key = findKey(dist);
  if (!key) {
    console.error(`indexnow: no key file in ${dist}`);
    return 1;
  }
  const urls = changedUrls(dist, old);
  if (urls.length === 0) {
    console.log("indexnow: no page changed");
    return 0;
  }
  if (dryRun) {
    console.log(`indexnow: would submit ${urls.length} URL(s):\n${urls.join("\n")}`);
    return 0;
  }
  // 200 and 202 are both success; 202 means the key is still being checked.
  const status = await submit(urls, key);
  const ok = status === 200 || status === 202;
  (ok ? console.log : console.error)(`indexnow: submitted ${urls.length} URL(s), answered ${status}`);
  return ok ? 0 : 1;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).then((code) => { process.exitCode = code; }, (err) => {
    console.error(`indexnow: ${err.message}`);
    process.exitCode = 1;
  });
}
