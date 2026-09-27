import assert from "node:assert/strict";
import { test } from "node:test";
import { cronwatch, memory } from "../src/index.js";
import { capture, clock, HOUR, MIN, T0 } from "./helpers.js";

/** A board with a daily cron that failed today, an interval job that stopped, and a busy one. */
async function seeded() {
  const c = clock(T0 - 30 * HOUR);
  const cw = cronwatch({ now: c.now, alerts: [capture()], cronSecret: null });
  const routes = cw.routes({ token: "tok", basePath: "/cronwatch" });
  const get = async (path: string) => (await routes.GET(new Request(`http://app.test${path}`, { headers: { authorization: "Bearer tok" } }))).text();
  const day = Date.UTC(2026, 0, 5);

  const hourly = cw.job("hourly", { schedule: "0 * * * *", timezone: "UTC" });
  for (let t = day - 24 * HOUR; t <= T0 - 30 * MIN; t += HOUR) {
    c.set(t);
    await hourly.run(async () => { c.advance(5 * MIN); });
  }
  const nightly = cw.job("nightly", { schedule: "0 3 * * *", timezone: "UTC" });
  c.set(day + 3 * HOUR);
  await assert.rejects(nightly.run(async () => { c.advance(400); throw new Error("boom"); }));

  const sync = cw.job("sync", { schedule: "every 30m", grace: "5m" });
  c.set(T0 - 2 * HOUR);
  await sync.run(async () => { c.advance(8000); });

  const busy = cw.job("busy", { schedule: "every 5m", grace: "4m" });
  for (let t = T0 - 3 * HOUR; t < T0; t += 5 * MIN) {
    c.set(t);
    await busy.run(async () => { c.advance(1000); });
  }
  c.set(T0);
  await cw.check();
  return { cw, c, get };
}

test("the board draws a day timeline: due ticks, runs as wide as they took, a missed box and a now line", async () => {
  const { get } = await seeded();
  const html = await get("/cronwatch/");
  const lanes = /<ol class="lanes">([\s\S]*?)<\/ol>/.exec(html)![1]!;
  const lane = (name: string) => lanes.split("<li ").find((l) => l.includes(`>${name}</a>`))!;

  // Hourly: a tick for every hour in the last day and the next three, one ok run for each past hour.
  const hourly = lane("hourly");
  assert.equal((hourly.match(/<line class="tick"/g) ?? []).length, 24, "a tick each hour of the last day");
  assert.equal((hourly.match(/<line class="tick ahead"/g) ?? []).length, 3, "and dashed ones ahead");
  assert.ok((hourly.match(/class="run ok"/g) ?? []).length >= 23);
  assert.match(hourly, /<title>hourly: ok at 09:00 UTC, took 5m<\/title>/);

  // The failed nightly run is a red mark with a note beside it.
  const nightly = lane("nightly");
  assert.match(nightly, /class="run bad"[^>]*><title>nightly: failed at 03:00 UTC, took 400ms<\/title>/);
  assert.match(nightly, /<span class="note[^"]*"[^>]*>failed at 03:00<\/span>/);

  // Sync stopped: due 08:00, nothing started, so a dashed box and a note.
  const sync = lane("sync");
  assert.match(sync, /<rect class="missed"[^>]*><title>sync: due 08:00 UTC, nothing started/);
  assert.match(sync, />due 08:00, nothing ran<\/span>/);

  // Busy runs every 5m, more than the table's twenty runs: the lane reads deeper and draws them all.
  assert.equal((lane("busy").match(/class="run ok"/g) ?? []).length, 36);

  assert.match(html, /<i class="now" style="left:[\d.]+%"><\/i>/);
  assert.match(html, /<span class="nowlabel"[^>]*>now 09:30<\/span>/);
  assert.match(html, /<ul class="vh"><li>busy \(every 5m\): /, "the same in words for screen readers");
  assert.match(html, /@media\(prefers-reduced-motion:reduce\)\{[^}]*animation:none!important/);
  assert.doesNotMatch(html, /<script/i);
  assert.equal(/<p class="headline">(.*?)<\/p>/.exec(html)![1], "4 jobs, <b>2 needing attention</b>.");
});

test("a job page draws its last seven days, today first", async () => {
  const { get } = await seeded();
  const html = await get("/cronwatch/jobs/hourly");
  const week = /<figure class="timeline week">([\s\S]*?)<\/figure>/.exec(html)![1]!;
  assert.equal((week.match(/<li class="lane/g) ?? []).length, 7);
  assert.match(week, /Today, 5 Jan/);
  assert.match(week, /Sun 4 Jan<\/span><span class="sched">24 runs/);
  assert.match(week, /<line class="nowline"/, "a now line on today's lane only");
  assert.equal((week.match(/class="nowline"/g) ?? []).length, 1);
});

test("job names are escaped inside the timeline's SVG and notes", async () => {
  // Names made through cw.job are plain, but a store can hold anything another writer put there.
  const c = clock();
  const store = memory();
  const cw = cronwatch({ now: c.now, store, alerts: [capture()], cronSecret: null });
  const name = `<svg onload=alert(1)>"&'`;
  await store.upsertJob({ name, schedule: "0 * * * *", timezone: "UTC" }, T0 - HOUR);
  await store.insertRun({ id: "r1", job: name, status: "failed", startedAt: T0 - 10 * MIN, finishedAt: T0 - 9 * MIN, durationMs: MIN, error: "x", output: null, metrics: {}, trigger: "run" });
  const routes = cw.routes({ token: null, basePath: "/cronwatch" });
  for (const path of ["/cronwatch/", `/cronwatch/jobs/${encodeURIComponent(name)}`]) {
    const html = await (await routes.GET(new Request(`http://app.test${path}`))).text();
    assert.doesNotMatch(html, /<svg onload/, path);
    assert.doesNotMatch(html, /<[a-z]+ onload/i, path);
    assert.match(html, /<title>&lt;svg onload=alert\(1\)&gt;&quot;&amp;&#39;[^<]*: failed at 09:20 UTC/, path);
  }
});

test("the board draws at most thirty lanes and says so", async () => {
  const c = clock();
  const cw = cronwatch({ now: c.now, alerts: [capture()], cronSecret: null });
  for (let i = 0; i < 33; i++) await cw.run(`job-${String(i).padStart(2, "0")}`, async () => {});
  const routes = cw.routes({ token: null, basePath: "/cronwatch" });
  const html = await (await routes.GET(new Request("http://app.test/cronwatch/"))).text();
  assert.equal((html.match(/<li class="lane">/g) ?? []).length, 30);
  assert.match(html, /Showing the first 30 of 33 jobs here/);
  assert.equal((html.match(/<td class="job">/g) ?? []).length, 33, "the table lists every job");
});

test("an empty store shows no timeline", async () => {
  const cw = cronwatch({ alerts: [capture()], cronSecret: null });
  const routes = cw.routes({ token: null, basePath: "/cronwatch" });
  const html = await (await routes.GET(new Request("http://app.test/cronwatch/"))).text();
  assert.match(html, /No jobs yet\./);
  assert.doesNotMatch(html, /class="timeline/);
});

test("a job due more often than can be drawn shows its cadence as a line, not a thousand ticks", async () => {
  const c = clock();
  const cw = cronwatch({ now: c.now, alerts: [capture()], cronSecret: null });
  await cw.job("minutely", { schedule: "* * * * *" }).run(async () => {});
  const routes = cw.routes({ token: null, basePath: "/cronwatch" });
  const html = await (await routes.GET(new Request("http://app.test/cronwatch/"))).text();
  assert.match(html, /<line class="cadence"[^>]*><title>minutely: due \* \* \* \* \*, too often to mark each time<\/title>/);
  assert.doesNotMatch(html, /class="tick[^"]*" x1="[\d.]+" y1="6"/, "no ticks in the lane");
});
