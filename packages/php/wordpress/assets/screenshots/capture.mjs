// Captures the four listing screenshots from the running WordPress
// (http://store.example.com, mapped to the cws-wp container on 8088) into
// the directory given as argv[2]. PLAYWRIGHT is Playwright's package
// directory; CWS_WORK holds R.txt, the seeded "now" (epoch ms).
import { readFileSync } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const OUT = process.argv[2];
const { chromium } = await import(pathToFileURL(path.join(process.env.PLAYWRIGHT, "index.mjs")).href);
const R = Number(readFileSync(path.join(process.env.CWS_WORK, "R.txt"), "utf8"));
if (Date.now() < R) {
  console.log(`waiting ${Math.ceil((R - Date.now()) / 1000)}s for the seeded now`);
  await new Promise((r) => setTimeout(r, R - Date.now() + 2000));
}

const browser = await chromium.launch({ args: ["--host-resolver-rules=MAP store.example.com:80 127.0.0.1:8088"] });
const context = await browser.newContext({ viewport: { width: 1380, height: 1100 }, deviceScaleFactor: 1 });
const page = await context.newPage();
const BASE = "http://store.example.com";
await page.goto(`${BASE}/wp-login.php`);
await page.fill("#user_login", "admin");
await page.fill("#user_pass", "cws-shots-pass");
await Promise.all([page.waitForNavigation(), page.click("#wp-submit")]);

const frameReady = async () => {
  const handle = await page.waitForSelector("iframe");
  const frame = await handle.contentFrame();
  await frame.waitForLoadState("load");
  await frame.evaluate(() => document.fonts.ready);
  // The dashboard draws its marks in with CSS animations; let them finish.
  await page.waitForTimeout(4000);
  return frame;
};

// 1. The dashboard: health and the last 24 hours.
await page.goto(`${BASE}/wp-admin/admin.php?page=cronwatch`);
const frame = await frameReady();
await page.mouse.move(0, 0);
await page.screenshot({ path: path.join(OUT, "screenshot-1.png") });

// 2. An event's page: the failing one, reached by its link on the dashboard.
await page.setViewportSize({ width: 1380, height: 1600 });
await Promise.all([frame.waitForNavigation(), frame.click('a:has-text("wp:store_sync_inventory")')]);
await frameReady();
await page.mouse.move(0, 0);
await page.screenshot({ path: path.join(OUT, "screenshot-2.png") });

// 3. The settings form, down to its Save button.
await page.setViewportSize({ width: 1380, height: 1100 });
await page.goto(`${BASE}/wp-admin/admin.php?page=cronwatch-settings`);
const save = await page.locator('#wpbody input[type="submit"], #wpbody button[type="submit"]').first().boundingBox();
await page.screenshot({ path: path.join(OUT, "screenshot-3.png"), fullPage: true, clip: { x: 0, y: 0, width: 1380, height: Math.round(save.y + save.height + 28) } });

// 4. The test alert button and the watched events.
const test = await page.locator('#wpbody :is(input, button):is([value="Send a test alert"], :text("Send a test alert"))').first().boundingBox();
const table = await page.locator("#wpbody table.widefat").boundingBox();
const top = Math.round(test.y - 28);
await page.screenshot({ path: path.join(OUT, "screenshot-4.png"), fullPage: true, clip: { x: 160, y: top, width: 1220, height: Math.round(table.y + table.height + 29 - top) } });

await browser.close();
console.log("captured screenshot-1.png to screenshot-4.png");
