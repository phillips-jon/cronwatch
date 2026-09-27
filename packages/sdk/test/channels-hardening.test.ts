import assert from "node:assert/strict";
import http from "node:http";
import type { AddressInfo } from "node:net";
import { test } from "node:test";
import { bugsnag } from "../src/alerts/bugsnag.js";
import { datadog } from "../src/alerts/datadog.js";
import { discord } from "../src/alerts/discord.js";
import { composeEmail } from "../src/alerts/email.js";
import { honeybadger } from "../src/alerts/honeybadger.js";
import { mailgun } from "../src/alerts/mailgun.js";
import { newrelic } from "../src/alerts/newrelic.js";
import { postmark } from "../src/alerts/postmark.js";
import { resend } from "../src/alerts/resend.js";
import { rollbar } from "../src/alerts/rollbar.js";
import { sendgrid } from "../src/alerts/sendgrid.js";
import { sentry } from "../src/alerts/sentry.js";
import { ses } from "../src/alerts/ses.js";
import { errorBody } from "../src/alerts/shared.js";
import { slack } from "../src/alerts/slack.js";
import { smsBody, smsSegments, twilio } from "../src/alerts/twilio.js";
import { webhook } from "../src/alerts/webhook.js";
import { composeAlert } from "../src/format.js";
import { cronwatch } from "../src/index.js";
import type { Alert, AlertChannel } from "../src/types.js";
import { clock, T0 } from "./helpers.js";

const failed = (extra: Partial<Alert> = {}): Alert => ({
  ...composeAlert({ type: "failed", run: null, details: { consecutiveFailures: 1, threshold: 1 } }, { name: "nightly" }, T0),
  ...extra,
} as Alert);

function stubFetch(t: { after(fn: () => void): void }, answer: (url: string, init: RequestInit) => Response) {
  const calls: { url: string; init: RequestInit }[] = [];
  const original = globalThis.fetch;
  globalThis.fetch = (async (url: string, init: RequestInit) => {
    calls.push({ url: String(url), init });
    return answer(String(url), init);
  }) as typeof fetch;
  t.after(() => { globalThis.fetch = original; });
  return calls;
}

test("a secret that straddles the cut in a provider's error body is still cut out", async (t) => {
  const key = "key-0123456789abcdef0123456789abcdef";
  stubFetch(t, () => new Response("x".repeat(180) + `invalid key ${key}`, { status: 401 }));
  await assert.rejects(mailgun({ apiKey: key, domain: "mg.example.com", from: "a@b.c", to: "d@e.f" }).send(failed()), (error: Error) => {
    for (let i = 0; i + 6 <= key.length; i++) assert.ok(!error.message.includes(key.slice(i, i + 6)), `a piece of the key survives: ${error.message}`);
    assert.match(error.message, /: x{180}invalid key \[redacte$/, "cut to 200 after the key was taken out");
    return true;
  });
  assert.equal(errorBody("a".repeat(199) + "\u{1F600}tail"), "a".repeat(199), "never half a surrogate pair");
  assert.equal(errorBody("short"), "short");
  assert.equal(errorBody(`${"y".repeat(10)}sekret${"z".repeat(300)}`, ["sekret"]).slice(0, 20), `${"y".repeat(10)}[redacted]`);
  assert.equal(errorBody("z".repeat(300), ["sekret"]).length, 200);
});

test("every channel refuses to follow a redirect, so its credentials never reach another origin", async (t) => {
  const seen: string[] = [];
  const evil = http.createServer((req, res) => { seen.push(JSON.stringify(req.headers)); res.writeHead(202); res.end(); }).listen(0, "127.0.0.1");
  await new Promise((r) => evil.once("listening", r));
  const evilUrl = `http://127.0.0.1:${(evil.address() as AddressInfo).port}/steal`;
  const provider = http.createServer((_req, res) => { res.writeHead(307, { location: evilUrl }); res.end(); }).listen(0, "127.0.0.1");
  await new Promise((r) => provider.once("listening", r));
  const providerUrl = `http://127.0.0.1:${(provider.address() as AddressInfo).port}/in`;
  t.after(() => { evil.close(); provider.close(); });
  const realFetch = globalThis.fetch;
  const inits: RequestInit[] = [];
  globalThis.fetch = ((_url: string, init: RequestInit) => { inits.push(init); return realFetch(providerUrl, init); }) as typeof fetch;
  t.after(() => { globalThis.fetch = realFetch; });
  const email = { from: "a@b.c", to: "d@e.f" };
  const channels: AlertChannel[] = [
    datadog({ apiKey: "dd-secret-key-123" }),
    resend({ apiKey: "re_secret", ...email }),
    postmark({ serverToken: "pm-secret", ...email }),
    sendgrid({ apiKey: "SG.secret", ...email }),
    mailgun({ apiKey: "key-secret", domain: "mg.example.com", ...email }),
    ses({ region: "us-east-1", accessKeyId: "AKIDEXAMPLE", secretAccessKey: "sekret-sekret", ...email }),
    twilio({ accountSid: "AC1", authToken: "tw-secret", from: "+1", to: "+2" }),
    sentry({ dsn: "https://pubkey@o1.ingest.sentry.io/42" }),
    honeybadger({ apiKey: "hb-secret" }),
    rollbar({ accessToken: "rb-secret" }),
    bugsnag({ apiKey: "bs-secret" }),
    newrelic({ accountId: "1", apiKey: "nr-secret" }),
    webhook({ url: providerUrl, headers: { authorization: "Bearer wh-secret" }, secret: "s" }),
    slack({ webhookUrl: providerUrl }),
    discord({ webhookUrl: providerUrl }),
  ];
  for (const channel of channels) await assert.rejects(channel.send(failed()), `${channel.name} followed the redirect`);
  assert.deepEqual(seen, [], "nothing reached the other origin");
  assert.ok(inits.every((init) => init.redirect === "error"));
});

test("twilio texts every number at once; one taking it is a delivery, and the refusals are reported", async (t) => {
  const sent: string[] = [];
  stubFetch(t, (_url, init) => {
    const to = new URLSearchParams(String(init.body)).get("To")!;
    if (to === "+15550000000") return new Response('{"code":21211,"message":"Invalid To"}', { status: 400 });
    sent.push(to);
    return new Response("{}", { status: 201 });
  });
  const c = clock(Date.UTC(2026, 0, 1, 0, 0));
  const errors: string[] = [];
  const cw = cronwatch({
    now: c.now, cronSecret: null, onError: (e, where) => errors.push(`${where}: ${(e as Error).message}`),
    alerts: [twilio({ accountSid: "AC1", authToken: "tok", from: "+15551112222", to: ["+15553334444", "+15550000000"] })],
  });
  cw.job("nightly", { schedule: "0 * * * *" });
  await cw.check();
  for (let i = 0; i < 6; i++) {
    c.advance(70 * 60_000);
    await cw.check();
  }
  assert.deepEqual(sent, ["+15553334444"], "one SMS for one open missed condition, never resent");
  assert.equal(errors.length, 1);
  assert.match(errors[0]!, /^alert channel twilio: Twilio https:\/\/api\.twilio\.com answered 400: .*Invalid To.* \(to \*+0000; 1 of 2 numbers took the alert\)$/);

  // Every number refusing it is a failure, retried at the next check.
  stubFetch(t, () => new Response("no", { status: 500 }));
  await assert.rejects(twilio({ accountSid: "AC1", authToken: "tok", from: "+1", to: ["+2", "+3"] }).send(failed()), /\(2 of 2 numbers failed\)$/);
});

test("sms bodies stay inside Twilio's 1600 characters and pack segments as phones do", () => {
  const long = failed({ title: "j failed", message: "x".repeat(3000) });
  assert.ok(smsBody(long, undefined, 12).length <= 1530, "segments capped at 10");
  assert.ok(smsBody(long, undefined, Number.NaN).length <= 459, "not a number: the default 3");
  assert.equal(smsSegments("a".repeat(160)), 1);
  assert.equal(smsSegments("a".repeat(161)), 2);
  assert.equal(smsSegments("a".repeat(152) + "{" + "a".repeat(152)), 3, "an escape pair never straddles a segment");
  const packed = failed({ title: "t", message: ("a".repeat(152) + "{").repeat(3) });
  assert.ok(smsSegments(smsBody(packed, undefined, 3)) <= 3);
  assert.equal(smsSegments("\u{1F600}".repeat(35)), 1);
  assert.equal(smsSegments("a".repeat(66) + "\u{1F600}" + "a".repeat(66)), 3, "a surrogate pair never straddles a segment");
  const huge = smsBody(failed({ message: "m" }), `https://example.com/${"p".repeat(2000)}`, 10);
  assert.ok(huge.length <= 1600);
});

test("text cut for a subject or an error never leaves half a surrogate pair", () => {
  const email = composeEmail(failed({ title: "a".repeat(249) + "\u{1F600}" }), { from: "a@b.c", to: "d@e.f" }, ["d@e.f"]);
  assert.equal(email.subject, "a".repeat(249));
  assert.doesNotMatch(email.subject, /[\ud800-\udbff]$/);
});

test("credentials are trimmed before they go in a header", async (t) => {
  const calls = stubFetch(t, () => new Response("{}", { status: 200 }));
  const email = { from: "a@b.c", to: "d@e.f" };
  await resend({ apiKey: " re_secret\n", ...email }).send(failed());
  await postmark({ serverToken: "\tpm-secret ", ...email }).send(failed());
  await sendgrid({ apiKey: "SG.secret\n", ...email }).send(failed());
  await mailgun({ apiKey: " key-secret ", domain: "mg.example.com", ...email }).send(failed());
  await datadog({ apiKey: "dd-secret\n" }).send(failed());
  await honeybadger({ apiKey: " hb-secret" }).send(failed());
  await rollbar({ accessToken: "rb-secret \n" }).send(failed());
  await bugsnag({ apiKey: "bs-secret\n" }).send(failed());
  await newrelic({ accountId: "1", apiKey: " nr-secret" }).send(failed());
  await sentry({ dsn: " https://pubkey@o1.ingest.sentry.io/42\n" }).send(failed());
  await twilio({ accountSid: " AC1 ", authToken: "tok\n", from: "+1", to: "+2" }).send(failed());
  await ses({ region: "us-east-1", accessKeyId: " AKIDEXAMPLE", secretAccessKey: "sekret\n", ...email }).send(failed());
  await webhook({ url: "https://hooks.example.com/in", headers: { authorization: " Bearer wh-secret\n" } }).send(failed());
  for (const { init } of calls) {
    for (const [name, value] of Object.entries(init.headers as Record<string, string>)) {
      assert.equal(value, value.trim(), `${name} has spaces around it`);
    }
  }
  const headers = calls.map((c) => c.init.headers as Record<string, string>);
  assert.equal(headers[0]!.authorization, "Bearer re_secret");
  assert.equal(headers[1]!["x-postmark-server-token"], "pm-secret");
  assert.equal(headers[4]!["dd-api-key"], "dd-secret");
  assert.equal(JSON.parse(String(calls[7]!.init.body)).apiKey, "bs-secret");
  assert.equal(calls[10]!.url, "https://api.twilio.com/2010-04-01/Accounts/AC1/Messages.json");
  assert.equal(headers[10]!.authorization, `Basic ${btoa("AC1:tok")}`);
  assert.match(headers[11]!.authorization!, /^AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE\//);
  assert.equal(headers[12]!.authorization, "Bearer wh-secret");
  assert.throws(() => resend({ apiKey: "  ", ...email }), /needs an apiKey/);
});
