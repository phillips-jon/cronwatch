import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { test } from "node:test";
import { bugsnag } from "../src/alerts/bugsnag.js";
import { datadog } from "../src/alerts/datadog.js";
import { composeEmail, parseAddress } from "../src/alerts/email.js";
import { honeybadger } from "../src/alerts/honeybadger.js";
import { mailgun } from "../src/alerts/mailgun.js";
import { newrelic } from "../src/alerts/newrelic.js";
import { postmark } from "../src/alerts/postmark.js";
import { resend } from "../src/alerts/resend.js";
import { rollbar } from "../src/alerts/rollbar.js";
import { sendgrid } from "../src/alerts/sendgrid.js";
import { parseDsn, sentry } from "../src/alerts/sentry.js";
import { ses } from "../src/alerts/ses.js";
import { smsBody, twilio } from "../src/alerts/twilio.js";
import { signature, webhook } from "../src/alerts/webhook.js";
import { composeAlert } from "../src/format.js";
import type { Alert, AlertChannel, Run } from "../src/types.js";
import { T0 } from "./helpers.js";

const run: Run = {
  id: "r1", job: "nightly", status: "failed", startedAt: T0, finishedAt: T0 + 1000, durationMs: 1000,
  error: "Error: boom & <b>bust</b>", output: "before\n<script>alert(1)</script>\n\"quoted\" 'single'", metrics: {}, trigger: "run",
};

function failed(extra: Partial<Alert> = {}): Alert {
  return { ...composeAlert({ type: "failed", run, details: { consecutiveFailures: 1, threshold: 1 } }, { name: "nightly" }, T0 + 2000), ...extra } as Alert;
}
function slow(): Alert {
  return composeAlert({ type: "slow", run: { ...run, status: "ok", error: null }, details: { durationMs: 15_000, thresholdMs: 10_000, basis: "maxDuration" } }, { name: "nightly" }, T0) as Alert;
}
function recovered(): Alert {
  return composeAlert({ type: "recovered", run: { ...run, status: "ok", error: null }, details: { after: ["failed"] } }, { name: "nightly" }, T0 + 60_000) as Alert;
}
const link = (alert: Alert) => `https://app.example/cronwatch/jobs/${alert.job}`;

interface Call { url: string; init: RequestInit; headers: Record<string, string>; body: string }

/** Replaces fetch for one test, recording each request and answering `status`. */
function stubFetch(t: { after(fn: () => void): void }, status = 200, answer = "") {
  const calls: Call[] = [];
  const original = globalThis.fetch;
  globalThis.fetch = (async (url: string, init: RequestInit) => {
    calls.push({ url: String(url), init, headers: init.headers as Record<string, string>, body: String(init.body) });
    return new Response(status < 400 ? "{}" : answer, { status });
  }) as typeof fetch;
  t.after(() => { globalThis.fetch = original; });
  return calls;
}

/** Every channel: a failure names the provider and the origin, never a secret, and every request can time out. */
async function assertSafeFailure(t: { after(fn: () => void): void }, channel: AlertChannel, expected: RegExp, secrets: string[]) {
  const calls = stubFetch(t, 401, `bad key ${secrets[0]} given`);
  await assert.rejects(channel.send(failed()), (error: Error) => {
    assert.match(error.message, expected);
    for (const secret of secrets) assert.ok(!error.message.includes(secret), `${error.message} names a secret`);
    return true;
  });
  assert.ok(calls.length > 0);
  for (const call of calls) assert.ok(call.init.signal instanceof AbortSignal, "the request can time out");
}

// ---------------------------------------------------------------- email

test("email content: one line subject, the same text everywhere, escaped html, http links only", () => {
  const alert = failed({ title: "nightly\r\nBcc: x@evil.example failed", triage: "Check <the> & \"db\"" });
  const email = composeEmail(alert, { from: "a@b.c", to: "x@y.z", subjectPrefix: "[prod]", link }, ["x@y.z"]);
  assert.equal(email.subject, "[prod] nightly Bcc: x@evil.example failed");
  assert.ok(email.text.startsWith(alert.title + "\n\n" + alert.message));
  assert.match(email.text, /\nTriage: Check <the> & "db"\n\nOpen: https:\/\/app\.example\/cronwatch\/jobs\/nightly$/);
  assert.doesNotMatch(email.html, /<script>|<b>bust/);
  assert.match(email.html, /&lt;script&gt;alert\(1\)&lt;\/script&gt;/);
  assert.match(email.html, /&quot;quoted&quot; &#39;single&#39;/);
  assert.match(email.html, /<em>Triage:<\/em> Check &lt;the&gt; &amp; &quot;db&quot;/);
  assert.match(email.html, /<a href="https:\/\/app\.example\/cronwatch\/jobs\/nightly">/);
  assert.doesNotMatch(email.html, /src=|url\(/, "no remote assets");
  const js = composeEmail(alert, { from: "a@b.c", to: "x@y.z", link: () => "javascript:alert(1)" }, ["x@y.z"]);
  assert.doesNotMatch(js.html, /javascript:/);
  assert.doesNotMatch(js.text, /javascript:/);
});

test("parseAddress splits a display name", () => {
  assert.deepEqual(parseAddress("CronWatch <alerts@example.com>"), { email: "alerts@example.com", name: "CronWatch" });
  assert.deepEqual(parseAddress("\"Ops, Team\" <ops@example.com>"), { email: "ops@example.com", name: "Ops, Team" });
  assert.deepEqual(parseAddress("ops@example.com"), { email: "ops@example.com" });
});

test("email channels need from and to", () => {
  assert.throws(() => resend({ apiKey: "re_x", from: "", to: "a@b.c" }), /from/);
  assert.throws(() => postmark({ serverToken: "t", from: "a@b.c", to: [] }), /to address/);
  assert.throws(() => mailgun({ apiKey: "k", from: "a@b.c", to: "x@y.z", domain: "" }), /domain/);
  assert.throws(() => ses({ region: "us-east-1", accessKeyId: "", secretAccessKey: "s", from: "a@b.c", to: "x@y.z" }), /accessKeyId/);
});

test("resend posts json with a bearer key and an idempotency key per alert", async (t) => {
  const calls = stubFetch(t);
  await resend({ apiKey: "re_secret", from: "CronWatch <a@b.c>", to: ["x@y.z", "w@y.z"], link }).send(failed());
  await resend({ apiKey: "re_secret", from: "a@b.c", to: "x@y.z" }).send(failed());
  const [first, second] = calls;
  assert.equal(first!.url, "https://api.resend.com/emails");
  assert.equal(first!.headers.authorization, "Bearer re_secret");
  assert.match(first!.headers["idempotency-key"]!, /^cronwatch-[0-9a-f]{32}$/);
  assert.equal(first!.headers["idempotency-key"], second!.headers["idempotency-key"], "the same alert, the same key");
  const body = JSON.parse(first!.body);
  assert.deepEqual(Object.keys(body), ["from", "to", "subject", "text", "html"]);
  assert.deepEqual(body.to, ["x@y.z", "w@y.z"]);
  assert.equal(body.subject, "nightly failed");
  await assertSafeFailure(t, resend({ apiKey: "re_secret", from: "a@b.c", to: "x@y.z" }), /^Resend https:\/\/api\.resend\.com answered 401: bad key \[redacted\] given$/, ["re_secret"]);
});

test("postmark joins recipients and uses the server token header", async (t) => {
  const calls = stubFetch(t);
  await postmark({ serverToken: "pm-token", from: "a@b.c", to: ["x@y.z", "w@y.z"], messageStream: "alerts" }).send(failed());
  const { url, headers, body } = calls[0]!;
  assert.equal(url, "https://api.postmarkapp.com/email");
  assert.equal(headers["x-postmark-server-token"], "pm-token");
  assert.equal(headers.accept, "application/json");
  const parsed = JSON.parse(body);
  assert.equal(parsed.To, "x@y.z, w@y.z");
  assert.equal(parsed.MessageStream, "alerts");
  assert.ok(parsed.TextBody && parsed.HtmlBody);
  await assertSafeFailure(t, postmark({ serverToken: "pm-token", from: "a@b.c", to: "x@y.z" }), /^Postmark https:\/\/api\.postmarkapp\.com answered 401/, ["pm-token"]);
});

test("sendgrid sends personalizations and plain text before html, with an EU option", async (t) => {
  const calls = stubFetch(t);
  await sendgrid({ apiKey: "SG.secret", from: "CronWatch <a@b.c>", to: "Ops <x@y.z>" }).send(failed());
  await sendgrid({ apiKey: "SG.secret", from: "a@b.c", to: "x@y.z", region: "eu" }).send(failed());
  assert.equal(calls[0]!.url, "https://api.sendgrid.com/v3/mail/send");
  assert.equal(calls[1]!.url, "https://api.eu.sendgrid.com/v3/mail/send");
  assert.equal(calls[0]!.headers.authorization, "Bearer SG.secret");
  const body = JSON.parse(calls[0]!.body);
  assert.deepEqual(body.personalizations, [{ to: [{ email: "x@y.z", name: "Ops" }] }]);
  assert.deepEqual(body.from, { email: "a@b.c", name: "CronWatch" });
  assert.deepEqual(body.content.map((c: { type: string }) => c.type), ["text/plain", "text/html"]);
  await assertSafeFailure(t, sendgrid({ apiKey: "SG.secret", from: "a@b.c", to: "x@y.z" }), /^SendGrid https:\/\/api\.sendgrid\.com answered 401/, ["SG.secret"]);
});

test("mailgun form encodes with basic auth, one to per recipient, and an EU host", async (t) => {
  const calls = stubFetch(t);
  await mailgun({ apiKey: "key-secret", domain: "mg.example.com", from: "a@b.c", to: ["x@y.z", "w@y.z"] }).send(failed());
  await mailgun({ apiKey: "key-secret", domain: "mg.example.com", from: "a@b.c", to: "x@y.z", region: "eu" }).send(failed());
  const { url, headers, body } = calls[0]!;
  assert.equal(url, "https://api.mailgun.net/v3/mg.example.com/messages");
  assert.equal(calls[1]!.url, "https://api.eu.mailgun.net/v3/mg.example.com/messages");
  assert.equal(headers["content-type"], "application/x-www-form-urlencoded");
  assert.equal(headers.authorization, `Basic ${Buffer.from("api:key-secret").toString("base64")}`);
  const form = new URLSearchParams(body);
  assert.deepEqual(form.getAll("to"), ["x@y.z", "w@y.z"]);
  assert.equal(form.get("subject"), "nightly failed");
  assert.match(form.get("html")!, /&lt;script&gt;/);
  await assertSafeFailure(t, mailgun({ apiKey: "key-secret", domain: "mg.example.com", from: "a@b.c", to: "x@y.z" }), /^Mailgun https:\/\/api\.mailgun\.net answered 401/, ["key-secret", Buffer.from("api:key-secret").toString("base64")]);
});

test("ses signs a SendEmail v2 request with SigV4, deterministically for a fixed clock", async (t) => {
  const calls = stubFetch(t);
  const options = { region: "eu-west-1", accessKeyId: "AKIDEXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", sessionToken: "session-token", from: "a@b.c", to: "x@y.z", now: () => Date.UTC(2026, 0, 5, 9, 30) };
  await ses(options).send(failed());
  await ses(options).send(failed());
  const { url, headers, body } = calls[0]!;
  assert.equal(url, "https://email.eu-west-1.amazonaws.com/v2/email/outbound-emails");
  assert.equal(headers["x-amz-date"], "20260105T093000Z");
  assert.equal(headers["x-amz-security-token"], "session-token");
  assert.match(headers.authorization!, /^AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE\/20260105\/eu-west-1\/ses\/aws4_request, SignedHeaders=content-type;host;x-amz-date;x-amz-security-token, Signature=[0-9a-f]{64}$/);
  assert.equal(headers.authorization, calls[1]!.headers.authorization);
  const parsed = JSON.parse(body);
  assert.deepEqual(parsed.Destination, { ToAddresses: ["x@y.z"] });
  assert.equal(parsed.Content.Simple.Subject.Data, "nightly failed");
  assert.ok(parsed.Content.Simple.Body.Text.Data && parsed.Content.Simple.Body.Html.Data);
  assert.throws(() => ses({ ...options, region: "evil.example/x" }), /region/);
  await assertSafeFailure(t, ses(options), /^SES https:\/\/email\.eu-west-1\.amazonaws\.com answered 401/, [options.secretAccessKey, "session-token"]);
});

// ---------------------------------------------------------------- sms

test("twilio texts each number, form encoded, with basic auth", async (t) => {
  const calls = stubFetch(t);
  await twilio({ accountSid: "AC123", authToken: "tw-token", from: "+15005550006", to: ["+15551110000", "+15552220000"], link }).send(failed());
  assert.equal(calls.length, 2);
  const { url, headers, body } = calls[0]!;
  assert.equal(url, "https://api.twilio.com/2010-04-01/Accounts/AC123/Messages.json");
  assert.equal(headers.authorization, `Basic ${Buffer.from("AC123:tw-token").toString("base64")}`);
  const form = new URLSearchParams(body);
  assert.equal(form.get("To"), "+15551110000");
  assert.equal(form.get("From"), "+15005550006");
  assert.ok(form.get("Body")!.startsWith("nightly failed\n"));
  assert.ok(form.get("Body")!.endsWith("\nhttps://app.example/cronwatch/jobs/nightly"));
  assert.equal(new URLSearchParams(calls[1]!.body).get("To"), "+15552220000");
});

test("twilio uses an API key and messaging service when given, and skips recoveries by default", async (t) => {
  const calls = stubFetch(t);
  const channel = twilio({ accountSid: "AC123", apiKeySid: "SK1", apiKeySecret: "sk-secret", messagingServiceSid: "MG1", to: "+15551110000" });
  await channel.send(recovered());
  assert.equal(calls.length, 0);
  await channel.send(failed());
  assert.equal(calls[0]!.headers.authorization, `Basic ${Buffer.from("SK1:sk-secret").toString("base64")}`);
  const form = new URLSearchParams(calls[0]!.body);
  assert.equal(form.get("MessagingServiceSid"), "MG1");
  assert.equal(form.get("From"), null);
  await twilio({ accountSid: "AC123", authToken: "t", from: "+1", to: "+2", recovered: true }).send(recovered());
  assert.equal(calls.length, 2);
});

test("twilio tries every number and reports how many failed, without the token", async (t) => {
  const calls = stubFetch(t, 400, "tw-token rejected");
  await assert.rejects(
    twilio({ accountSid: "AC123", authToken: "tw-token", from: "+1", to: ["+2", "+3"] }).send(failed()),
    (error: Error) => error.message === "Twilio https://api.twilio.com answered 400: [redacted] rejected (2 of 2 numbers failed)",
  );
  assert.equal(calls.length, 2);
  await assertSafeFailure(t, twilio({ accountSid: "AC123", authToken: "tw-token", from: "+1", to: "+2" }), /^Twilio https:\/\/api\.twilio\.com answered 401/, ["tw-token"]);
});

test("sms bodies fit three segments, GSM or not, and keep the link whole", () => {
  const long = failed({ message: "x".repeat(2000) });
  const gsm = smsBody(long, "https://app.example/j");
  assert.ok(gsm.length <= 459, `${gsm.length}`);
  assert.ok(gsm.endsWith("...\nhttps://app.example/j"));
  const emoji = failed({ message: "\u{1F600}".repeat(500) });
  const ucs = smsBody(emoji, undefined);
  assert.ok(ucs.length <= 201, `${ucs.length}`);
  assert.doesNotMatch(ucs, /[\ud800-\udbff](?![\udc00-\udfff])/, "no split surrogate pair");
  assert.equal(smsBody(failed({ message: "one\ntwo" }), undefined), "nightly failed\none\ntwo");
  assert.equal(smsBody(failed({ message: "one", triage: "db down" }), undefined), "nightly failed\none\nTriage: db down");
});

// ---------------------------------------------------------------- trackers

test("sentry parses a DSN and sends an envelope with the auth header", async (t) => {
  assert.deepEqual(parseDsn("https://pub@o1.ingest.sentry.io/42"), { endpoint: "https://o1.ingest.sentry.io/api/42/envelope/", publicKey: "pub" });
  assert.deepEqual(parseDsn("https://pub@sentry.example.com/prefix/7"), { endpoint: "https://sentry.example.com/prefix/api/7/envelope/", publicKey: "pub" });
  assert.throws(() => sentry({ dsn: "https://o1.ingest.sentry.io/42" }), /dsn/);
  const calls = stubFetch(t);
  const channel = sentry({ dsn: "https://pubkey@o1.ingest.sentry.io/42", environment: "staging", release: "app@1", link });
  await channel.send(failed({ triage: "db down" }));
  await channel.send(slow());
  await channel.send(recovered());
  const { url, headers, body } = calls[0]!;
  assert.equal(url, "https://o1.ingest.sentry.io/api/42/envelope/");
  assert.equal(headers["content-type"], "application/x-sentry-envelope");
  assert.equal(headers["x-sentry-auth"], "Sentry sentry_version=7, sentry_key=pubkey, sentry_client=cronwatch");
  const [envelopeHeader, itemHeader, payload, end] = body.split("\n");
  assert.equal(end, "");
  const event = JSON.parse(payload!);
  assert.equal(JSON.parse(envelopeHeader!).event_id, event.event_id);
  assert.match(event.event_id, /^[0-9a-f]{32}$/);
  assert.deepEqual(JSON.parse(itemHeader!), { type: "event", content_type: "application/json", length: Buffer.byteLength(payload!) });
  assert.equal(event.level, "error");
  assert.equal(event.timestamp, (T0 + 2000) / 1000);
  assert.deepEqual(event.fingerprint, ["cronwatch", "nightly", "failed"]);
  assert.deepEqual(event.tags, { job: "nightly", type: "failed" });
  assert.equal(event.environment, "staging");
  assert.equal(event.release, "app@1");
  assert.ok(event.logentry.formatted.startsWith("nightly failed\n\n"));
  assert.equal(event.extra.triage, "db down");
  assert.equal(event.extra.link, "https://app.example/cronwatch/jobs/nightly");
  assert.equal(JSON.parse(calls[1]!.body.split("\n")[2]!).level, "warning");
  assert.equal(JSON.parse(calls[2]!.body.split("\n")[2]!).level, "info");
  await assertSafeFailure(t, sentry({ dsn: "https://pubkey@o1.ingest.sentry.io/42" }), /^Sentry https:\/\/o1\.ingest\.sentry\.io answered 401/, ["pubkey"]);
});

test("honeybadger sends a notice with a fingerprint per job and type, and skips recoveries by default", async (t) => {
  const calls = stubFetch(t);
  await honeybadger({ apiKey: "hb-key", environment: "staging", link }).send(failed());
  await honeybadger({ apiKey: "hb-key" }).send(recovered());
  await honeybadger({ apiKey: "hb-key", endpoint: "https://eu-api.honeybadger.io/", recovered: true }).send(recovered());
  assert.equal(calls.length, 2);
  const { url, headers, body } = calls[0]!;
  assert.equal(url, "https://api.honeybadger.io/v1/notices");
  assert.equal(headers["x-api-key"], "hb-key");
  const notice = JSON.parse(body);
  assert.equal(notice.error.class, "CronWatch::Failed");
  assert.equal(notice.error.fingerprint, "cronwatch:nightly:failed");
  assert.deepEqual(notice.error.tags, ["cronwatch", "failed"]);
  assert.equal(notice.server.environment_name, "staging");
  assert.equal(notice.request.url, "https://app.example/cronwatch/jobs/nightly");
  assert.equal(calls[1]!.url, "https://eu-api.honeybadger.io/v1/notices");
  assert.equal(JSON.parse(calls[1]!.body).error.class, "CronWatch::Recovered");
  await assertSafeFailure(t, honeybadger({ apiKey: "hb-key" }), /^Honeybadger https:\/\/api\.honeybadger\.io answered 401/, ["hb-key"]);
});

test("datadog posts a v1 event with alert_type, aggregation key, tags and a site", async (t) => {
  const calls = stubFetch(t);
  await datadog({ apiKey: "dd-key", tags: ["env:prod"], link }).send(failed());
  await datadog({ apiKey: "dd-key", site: "datadoghq.eu" }).send(slow());
  await datadog({ apiKey: "dd-key", site: "https://app.us5.datadoghq.com/" }).send(recovered());
  const { url, headers, body } = calls[0]!;
  assert.equal(url, "https://api.datadoghq.com/api/v1/events");
  assert.equal(calls[1]!.url, "https://api.datadoghq.eu/api/v1/events");
  assert.equal(calls[2]!.url, "https://api.us5.datadoghq.com/api/v1/events");
  assert.equal(headers["dd-api-key"], "dd-key");
  const event = JSON.parse(body);
  assert.equal(event.alert_type, "error");
  assert.equal(event.aggregation_key, "cronwatch:nightly:failed");
  assert.deepEqual(event.tags, ["cronwatch", "job:nightly", "alert:failed", "env:prod"]);
  assert.equal(event.date_happened, Math.floor((T0 + 2000) / 1000));
  assert.ok(event.text.length <= 4000);
  assert.match(event.text, /Open: https:\/\/app\.example/);
  assert.equal(JSON.parse(calls[1]!.body).alert_type, "warning");
  assert.equal(JSON.parse(calls[2]!.body).alert_type, "success");
  const longJob = failed({ job: "j".repeat(200) });
  await datadog({ apiKey: "dd-key" }).send(longJob);
  assert.ok(JSON.parse(calls[3]!.body).aggregation_key.length <= 100);
  assert.throws(() => datadog({ apiKey: "k", site: "evil.example/x?" }), /site/);
  await assertSafeFailure(t, datadog({ apiKey: "dd-key" }), /^Datadog https:\/\/api\.datadoghq\.com answered 401/, ["dd-key"]);
});

test("rollbar posts an item with level, fingerprint and a stable uuid", async (t) => {
  const calls = stubFetch(t);
  await rollbar({ accessToken: "rb-token", environment: "staging", link }).send(failed({ triage: "db down" }));
  await rollbar({ accessToken: "rb-token" }).send(recovered());
  await rollbar({ accessToken: "rb-token", recovered: false }).send(recovered());
  assert.equal(calls.length, 2);
  const { url, headers, body } = calls[0]!;
  assert.equal(url, "https://api.rollbar.com/api/1/item/");
  assert.equal(headers["x-rollbar-access-token"], "rb-token");
  const { data } = JSON.parse(body);
  assert.equal(data.level, "error");
  assert.equal(data.environment, "staging");
  assert.equal(data.fingerprint, "cronwatch:nightly:failed");
  assert.match(data.uuid, /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/);
  assert.equal(data.title, "nightly failed");
  assert.equal(data.custom.triage, "db down");
  assert.equal(JSON.parse(calls[1]!.body).data.level, "info");
  await assertSafeFailure(t, rollbar({ accessToken: "rb-token" }), /^Rollbar https:\/\/api\.rollbar\.com answered 401/, ["rb-token"]);
});

test("bugsnag sends payload version 5 with a grouping hash per job and type", async (t) => {
  const calls = stubFetch(t);
  const now = () => Date.UTC(2026, 0, 5, 9, 30);
  await bugsnag({ apiKey: "bs-key", releaseStage: "staging", now, link }).send(slow());
  await bugsnag({ apiKey: "bs-key", now }).send(recovered());
  await bugsnag({ apiKey: "bs-key", now, recovered: true }).send(recovered());
  assert.equal(calls.length, 2);
  const { url, headers, body } = calls[0]!;
  assert.equal(url, "https://notify.bugsnag.com/");
  assert.equal(headers["bugsnag-api-key"], "bs-key");
  assert.equal(headers["bugsnag-payload-version"], "5");
  assert.equal(headers["bugsnag-sent-at"], "2026-01-05T09:30:00.000Z");
  const payload = JSON.parse(body);
  assert.equal(payload.payloadVersion, "5");
  const [event] = payload.events;
  assert.equal(event.severity, "warning");
  assert.equal(event.groupingHash, "cronwatch:nightly:slow");
  assert.equal(event.context, "nightly");
  assert.equal(event.app.releaseStage, "staging");
  assert.equal(event.exceptions[0].errorClass, "CronWatch slow");
  assert.equal(event.metaData.cronwatch.link, "https://app.example/cronwatch/jobs/nightly");
  assert.equal(JSON.parse(calls[1]!.body).events[0].severity, "info");
  await assertSafeFailure(t, bugsnag({ apiKey: "bs-key" }), /^Bugsnag https:\/\/notify\.bugsnag\.com answered 401/, ["bs-key"]);
});

test("newrelic records a CronWatchAlert custom event, with an EU option", async (t) => {
  const calls = stubFetch(t);
  await newrelic({ accountId: 12345, apiKey: "nr-key", link }).send(failed({ triage: "t".repeat(5000) }));
  await newrelic({ accountId: "12345", apiKey: "nr-key", region: "eu" }).send(recovered());
  const { url, headers, body } = calls[0]!;
  assert.equal(url, "https://insights-collector.newrelic.com/v1/accounts/12345/events");
  assert.equal(calls[1]!.url, "https://insights-collector.eu01.nr-data.net/v1/accounts/12345/events");
  assert.equal(headers["api-key"], "nr-key");
  const [event] = JSON.parse(body);
  assert.equal(event.eventType, "CronWatchAlert");
  assert.equal(event.timestamp, T0 + 2000);
  assert.equal(event.job, "nightly");
  assert.equal(event.alertType, "failed");
  assert.equal(event.severity, "error");
  assert.equal(event.runId, "r1");
  assert.ok(event.triage.length < 4096);
  assert.equal(JSON.parse(calls[1]!.body)[0].severity, "info");
  assert.throws(() => newrelic({ accountId: "../x", apiKey: "k" }), /accountId/);
  await assertSafeFailure(t, newrelic({ accountId: 1, apiKey: "nr-key" }), /^New Relic https:\/\/insights-collector\.newrelic\.com answered 401/, ["nr-key"]);
});

// ---------------------------------------------------------------- webhook

test("webhook signs with Web Crypto, byte for byte what node:crypto signed before", async (t) => {
  const body = JSON.stringify({ type: "failed", job: "nightly", at: 1767605402000, title: "caf\u00e9 \u{1F600}" });
  const expected = "6adb916e3eeed59c49b4ea555ffb46d5a1a37980b03f078c6b9edaaa46c5ec1d";
  assert.equal(createHmac("sha256", "s3cret").update(body).digest("hex"), expected);
  assert.equal(await signature("s3cret", body), expected);
  const calls = stubFetch(t);
  const alert = failed();
  await webhook({ url: "https://hooks.example.com/in", secret: "s3cret" }).send(alert);
  const { headers, body: sent } = calls[0]!;
  assert.equal(headers["x-cronwatch-signature"], `sha256=${createHmac("sha256", "s3cret").update(sent).digest("hex")}`);
});
