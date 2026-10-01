// Names kept for 1.x under a new spelling, each marked @deprecated: the old
// name must keep doing exactly what the new one does until 2.0.
import assert from "node:assert/strict";
import { test } from "node:test";
import * as sdk from "../src/index.js";
import { Cronwatch, CronWatch, cronwatch } from "../src/index.js";
import type { CronwatchOptions, CronWatchOptions } from "../src/index.js";

test("CronWatch is Cronwatch, as a value and as a type", () => {
  assert.equal(CronWatch, Cronwatch);
  const old: CronWatch = new CronWatch({ alerts: [] });
  assert.ok(old instanceof Cronwatch);
  assert.ok(cronwatch({ alerts: [] }) instanceof CronWatch);
  const options: CronWatchOptions = { retention: "1d" } satisfies CronwatchOptions;
  assert.equal(new Cronwatch(options).retentionMs, 86_400_000);
  assert.ok("Cronwatch" in sdk && "CronWatch" in sdk);
});

test("the helpers the channel and source entry points leaked are still there, deprecated", async () => {
  const twilio = await import("../src/entries/twilio.js");
  const sms = await import("../src/alerts/twilio.js");
  assert.equal(twilio.smsBody, sms.smsBody);
  assert.equal(twilio.smsSegments, sms.smsSegments);
  assert.equal(twilio.MAX_BODY, 1600);
  assert.equal(twilio.MAX_SEGMENTS, 10);
  const sentry = await import("../src/entries/sentry.js");
  assert.equal(sentry.parseDsn, (await import("../src/alerts/sentry.js")).parseDsn);
  const discord = await import("../src/entries/discord.js");
  const embeds = await import("../src/alerts/discord.js");
  assert.equal(discord.embedDescription, embeds.embedDescription);
  assert.equal(discord.codeBlockSafe, embeds.codeBlockSafe);
  assert.equal(discord.escapeMarkdown, embeds.escapeMarkdown);
  assert.equal(discord.DESCRIPTION_MAX, 4096);
  const pg = await import("../src/entries/pg-cron.js");
  const source = await import("../src/sources/pgcron.js");
  assert.equal(pg.pgCronSchedule, source.pgCronSchedule);
  assert.equal(pg.pgCronJobName, source.pgCronJobName);
  assert.equal(pg.pgCronRun, source.pgCronRun);
  assert.equal(pg.PG_CRON_HOLD_MS, 600_000);
  // hmacSha256Hex is signature() under its old name.
  const webhook = await import("../src/entries/webhook.js");
  assert.equal(webhook.hmacSha256Hex, webhook.signature);
  assert.equal(await webhook.signature("key", "The quick brown fox jumps over the lazy dog"), "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8");
  // Each entry point exports the channel or source, its types, and nothing else new.
  assert.deepEqual(Object.keys(twilio).sort(), ["MAX_BODY", "MAX_SEGMENTS", "smsBody", "smsSegments", "twilio"]);
  assert.deepEqual(Object.keys(sentry).sort(), ["parseDsn", "sentry"]);
  assert.deepEqual(Object.keys(discord).sort(), ["DESCRIPTION_MAX", "codeBlockSafe", "discord", "embedDescription", "escapeMarkdown"]);
  assert.deepEqual(Object.keys(pg).sort(), ["PG_CRON_HOLD_MS", "pgCron", "pgCronJobName", "pgCronRun", "pgCronSchedule"]);
  assert.deepEqual(Object.keys(webhook).sort(), ["hmacSha256Hex", "signature", "webhook"]);
});

test("createRoutes(cw, options) is cw.routes(options)", async () => {
  const cw = cronwatch({ alerts: [] });
  cw.job("a");
  const routes = sdk.createRoutes(cw, { token: "tok", basePath: "/cw" });
  const res = await routes.GET(new Request("http://app.test/cw/api/jobs", { headers: { authorization: "Bearer tok" } }));
  assert.equal(res.status, 200);
  assert.deepEqual((await res.json()).jobs.map((j: { name: string }) => j.name), ["a"]);
});
