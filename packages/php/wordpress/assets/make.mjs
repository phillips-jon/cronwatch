/**
 * Makes the plugin directory's icon and banner (the images in this folder,
 * which go to the plugin's SVN assets/ folder, not into the zip):
 *
 *     node packages/php/wordpress/assets/make.mjs
 *
 * icon.svg is the logo as the site's header draws it (the clock mark in its
 * rounded box, the one gradient); it is rendered to icon-128x128.png and
 * icon-256x256.png. banner.html is rendered to banner-772x250.png and, at
 * twice the density, banner-1544x500.png, with a strip of lanes redrawn
 * from the captured dashboard (site/src/demo/dashboard.html), so every mark
 * in it is one the library drew.
 *
 * Needs Playwright and Chrome, which the repository does not depend on:
 * install Playwright anywhere and set PLAYWRIGHT to its package directory
 * when it is not resolvable from here.
 *
 * The screenshots (screenshot-1.png to screenshot-4.png) are captures of a
 * real WordPress running the built plugin, not made here: screenshots/run.sh
 * retakes them.
 */
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "../../../..");
const pw = process.env.PLAYWRIGHT ? pathToFileURL(path.join(process.env.PLAYWRIGHT, "index.mjs")).href : "playwright";
const { chromium } = await import(pw);

/** The lanes to show, in order, from the captured dashboard. */
const LANES = ["sync-crm", "nightly-report", "invoice-run", "daily-digest"];
const W = 336, TOP = 24, LANE = 22;

function strip() {
  const html = readFileSync(path.join(ROOT, "site/src/demo/dashboard.html"), "utf8");
  const pct = (re) => [...html.matchAll(re)].map((m) => Number(m[1]));
  const grid = pct(/<i class="gl" style="left:([\d.]+)%"><\/i>/g);
  const [now] = pct(/<i class="future" style="left:([\d.]+)%"><\/i>/g);
  const X = (v) => (v / 1000) * W;
  const lanes = new Map();
  for (const [, body] of html.matchAll(/<li class="lane">(.*?)<\/li>/gs)) {
    const name = /class="name"[^>]*>([^<]+)</.exec(body)?.[1];
    if (name) lanes.set(name, body);
  }
  const bottom = TOP + LANES.length * LANE;
  const nowX = (now / 100) * W;
  let out = `<svg width="${W}" height="${bottom}" viewBox="0 0 ${W} ${bottom}" aria-hidden="true">`;
  out += `<rect class="future" x="${nowX.toFixed(1)}" y="${TOP - 4}" width="${(W - nowX).toFixed(1)}" height="${bottom - TOP + 4}"/>`;
  for (const g of grid) out += `<line class="gl" x1="${((g / 100) * W).toFixed(1)}" y1="${TOP - 4}" x2="${((g / 100) * W).toFixed(1)}" y2="${bottom}"/>`;
  out += `<text class="label" x="0" y="8">LAST 24 HOURS</text>`;
  out += `<text class="now-label" x="${nowX.toFixed(1)}" y="8" text-anchor="middle">now</text>`;
  LANES.forEach((name, i) => {
    const body = lanes.get(name);
    if (!body) throw new Error(`make: no lane ${name} in the captured dashboard`);
    const y = TOP + i * LANE, mid = y + LANE / 2;
    out += `<line class="base" x1="0" y1="${mid}" x2="${W}" y2="${mid}"/>`;
    for (const [, cls, x] of body.matchAll(/<line class="(tick(?: ahead)?)" x1="([\d.]+)"/g)) {
      out += `<line class="${cls}" x1="${X(Number(x)).toFixed(2)}" y1="${mid - 4.5}" x2="${X(Number(x)).toFixed(2)}" y2="${mid + 4.5}"/>`;
    }
    for (const [, cls, x, w] of body.matchAll(/<rect class="((?:run [a-z]+)|missed)" x="([\d.]+)" y="[\d.]+" width="([\d.]+)"/g)) {
      out += `<rect class="${cls}" x="${X(Number(x)).toFixed(2)}" y="${mid - 5.5}" width="${Math.max(X(Number(w)), 0.4).toFixed(2)}" height="11"/>`;
    }
  });
  out += `<line class="now" x1="${nowX.toFixed(1)}" y1="${TOP - 4}" x2="${nowX.toFixed(1)}" y2="${bottom}"/>`;
  return out + "</svg>";
}

const browser = await chromium.launch({ channel: "chrome" });
try {
  for (const [size, scale] of [[128, 1], [256, 2]]) {
    const page = await browser.newPage({ viewport: { width: 128, height: 128 }, deviceScaleFactor: scale });
    // An SVG with only a viewBox fills the viewport.
    await page.goto(pathToFileURL(path.join(HERE, "icon.svg")).href);
    await page.screenshot({ path: path.join(HERE, `icon-${size}x${size}.png`), omitBackground: true });
    await page.close();
  }
  const svg = strip();
  for (const [w, h, scale] of [[772, 250, 1], [1544, 500, 2]]) {
    const page = await browser.newPage({ viewport: { width: 772, height: 250 }, deviceScaleFactor: scale });
    await page.goto(pathToFileURL(path.join(HERE, "banner.html")).href);
    await page.evaluate((s) => { document.getElementById("strip").innerHTML = s; }, svg);
    await page.evaluate(() => document.fonts.ready);
    await page.screenshot({ path: path.join(HERE, `banner-${w}x${h}.png`) });
    await page.close();
  }
} finally {
  await browser.close();
}
console.log("make: wrote icon-128x128.png, icon-256x256.png, banner-772x250.png, banner-1544x500.png");
