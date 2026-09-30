// Captures the Plugin Store screenshots from the running Craft site
// (http://northwind.example.com, mapped to 127.0.0.1:$PORT) into the
// directory given as argv[2]: 1600x1000 at twice the pixels, light theme.
// PLAYWRIGHT is Playwright's package directory.
import { mkdirSync } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const OUT = process.argv[2];
const PORT = process.env.PORT || "8097";
mkdirSync(OUT, { recursive: true });
const { chromium } = await import(pathToFileURL(path.join(process.env.PLAYWRIGHT, "index.mjs")).href);

const browser = await chromium.launch({ args: [`--host-resolver-rules=MAP northwind.example.com:80 127.0.0.1:${PORT}`] });
const context = await browser.newContext({
  viewport: { width: 1600, height: 1000 },
  deviceScaleFactor: 2,
  colorScheme: "light",
  locale: "en-GB",
  timezoneId: "UTC",
});
const page = await context.newPage();
const BASE = "http://northwind.example.com";

await page.goto(`${BASE}/admin/login`);
await page.locator("input.login-username").first().fill("admin");
await page.locator("input.login-password").first().fill("cwc-shots-pass");
await Promise.all([page.waitForURL(/\/admin\/dashboard/), page.locator("button.submit[data-busy-message]").first().click()]);

/** The dashboard's frame on a CronWatch page, loaded, with its marks drawn in. */
const dashboard = async (url) => {
  await page.goto(url);
  const handle = await page.waitForSelector("iframe.cronwatch-dashboard-frame");
  const frame = await handle.contentFrame();
  await frame.waitForLoadState("load");
  await frame.evaluate(() => document.fonts.ready);
  // The dashboard draws its marks in with CSS animations; let them finish.
  await page.waitForTimeout(3500);
  return frame;
};
/** Scrolls the frame so the section headed `title` starts `gap` pixels from its top. */
const scrollTo = async (frame, title, gap = 24) => {
  await frame.evaluate(([title, gap]) => {
    const h2 = [...document.querySelectorAll("section h2")].find((h) => h.textContent.trim() === title);
    if (!h2) throw new Error(`no section ${title}`);
    const top = h2.closest("section").getBoundingClientRect().top + window.scrollY;
    window.scrollTo(0, Math.max(0, top - gap));
  }, [title, gap]);
  await page.waitForTimeout(300);
};
const shot = async (name) => {
  await page.mouse.move(1599, 999);
  await page.screenshot({ path: path.join(OUT, name) });
  console.log("captured", name);
};

// 1. The overview: the jobs' health and the last 24 hours.
let frame = await dashboard(`${BASE}/admin/cronwatch`);
await scrollTo(frame, "Health", 8);
await shot("1-overview.png");

// 2. The failing job's page: its state, numbers and week.
frame = await dashboard(`${BASE}/admin/cronwatch?job=${encodeURIComponent("craft:app:feeds:import")}`);
await shot("2-job.png");

// 3. The same job's runs, the newest (failed) one opened on its error and output.
await frame.evaluate(() => {
  const row = document.querySelector("table.runs tbody tr");
  for (const d of row.querySelectorAll("details")) d.open = true;
});
await scrollTo(frame, "Runs", 16);
await shot("3-failed-run.png");

// 4. The plugin's settings, channels filled in with made-up values.
await page.goto(`${BASE}/admin/settings/plugins/cronwatch`);
await page.waitForSelector('input[name="settings[emailTo]"], input[name="emailTo"], #settings-emailTo', { state: "attached" }).catch(() => {});
await page.evaluate(() => document.activeElement?.blur());
await page.waitForTimeout(800);
await shot("4-settings.png");

// 5. Every job on the board: the failing, the late (missed) and the slow among the healthy.
frame = await dashboard(`${BASE}/admin/cronwatch`);
await scrollTo(frame, "Jobs", 16);
await shot("5-jobs.png");

await browser.close();
