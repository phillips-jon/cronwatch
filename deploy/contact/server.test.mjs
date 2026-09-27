// The contact service, run as it runs on the server (a child process with
// its configuration in the environment), against a fake SES on 127.0.0.1.
//
//   node --test deploy/contact/server.test.mjs
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { after, before, beforeEach, test } from "node:test";
import { fileURLToPath } from "node:url";
import { checkForm, headerSafe, readConfig, signV4 } from "./server.mjs";

const SERVER = fileURLToPath(new URL("./server.mjs", import.meta.url));
// Made-up credentials, shaped like real ones so a leak would be easy to spot.
const KEY_ID = "AKIATESTONLY0CONTACT";
const SECRET = "tEsT0nly/SecretKey+DoNotUse0000000000000";
const TOKEN = "TestOnlySessionToken0000";

/* ---- The fake SES ---- */

let requests = [];
let sesStatus = 200;
const ses = createServer((req, res) => {
  const chunks = [];
  req.on("data", (c) => chunks.push(c));
  req.on("end", () => {
    requests.push({ method: req.method, url: req.url, headers: req.headers, body: JSON.parse(Buffer.concat(chunks).toString("utf8")) });
    if (sesStatus === 200) {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ MessageId: "test-message-id" }));
    } else {
      // A real AWS error echoes parts of the request; this one echoes the credential, to prove it is not logged.
      res.writeHead(sesStatus, { "content-type": "application/json", "x-amzn-ErrorType": "SignatureDoesNotMatch:http://internal.amazon.com/coral/" });
      res.end(JSON.stringify({ message: `bad signature for ${KEY_ID} ${SECRET}` }));
    }
  });
});

/* ---- The service ---- */

let child, base, output = "";

function start(env) {
  const proc = spawn(process.execPath, [SERVER], { env: { PATH: process.env.PATH, ...env }, stdio: ["ignore", "pipe", "pipe"] });
  let out = "";
  proc.stdout.on("data", (d) => { out += d; });
  proc.stderr.on("data", (d) => { out += d; });
  return { proc, output: () => out };
}

before(async () => {
  await new Promise((resolve) => ses.listen(0, "127.0.0.1", resolve));
  const s = start({
    AWS_ACCESS_KEY_ID: KEY_ID, AWS_SECRET_ACCESS_KEY: SECRET, AWS_SESSION_TOKEN: TOKEN, AWS_REGION: "us-east-1",
    CONTACT_FROM: "CronWatch <contact@example.com>", CONTACT_TO: "owner@example.com",
    CONTACT_PORT: "0", CONTACT_SES_URL: `http://127.0.0.1:${ses.address().port}/v2/email/outbound-emails`,
  });
  child = s.proc;
  base = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`the service did not start: ${s.output()}`)), 5000);
    child.stdout.on("data", () => {
      const m = /listening on (127\.0\.0\.1:\d+)/.exec(s.output());
      if (m) { clearTimeout(timer); resolve(`http://${m[1]}`); }
    });
  });
  child.stdout.on("data", (d) => { output += d; });
  child.stderr.on("data", (d) => { output += d; });
});

after(async () => {
  child?.kill("SIGTERM");
  await new Promise((resolve) => ses.close(resolve));
});

beforeEach(() => { requests = []; sesStatus = 200; });

const form = (fields) => new URLSearchParams({ name: "Ada Lovelace", email: "ada@example.com", message: "Hello.\nIt works.", website: "", t: "8000", ...fields }).toString();

async function post(body, { type = "application/x-www-form-urlencoded", method = "POST", path = "/contact", headers = {} } = {}) {
  const res = await fetch(`${base}${path}`, {
    method, redirect: "manual",
    headers: { ...(type ? { "content-type": type } : {}), "x-real-ip": "203.0.113.9", "user-agent": "TestBrowser/1.0", ...headers },
    ...(method === "GET" || method === "HEAD" ? {} : { body }),
  });
  const text = await res.text();
  return { status: res.status, location: res.headers.get("location"), headers: res.headers, text };
}

/** Waits for the service to log a line about a submission. */
async function logged(count) {
  for (let i = 0; i < 50; i++) {
    const lines = output.split("\n").filter((l) => l.startsWith("{"));
    if (lines.length >= count) return lines.map((l) => JSON.parse(l));
    await new Promise((r) => setTimeout(r, 20));
  }
  throw new Error(`expected ${count} log lines, got: ${output}`);
}
let seen = 0;
const nextLog = async () => (await logged(++seen))[seen - 1];

/* ---- Submissions ---- */

test("a valid message is sent through SES and redirects to the sent page", async () => {
  const r = await post(form({}));
  assert.equal(r.status, 303);
  assert.equal(r.location, "/contact/sent/");
  assert.equal(r.headers.get("cache-control"), "no-store");
  assert.equal(requests.length, 1);
  const [req] = requests;
  assert.equal(req.method, "POST");
  assert.equal(req.url, "/v2/email/outbound-emails");
  assert.match(req.headers.authorization, new RegExp(`^AWS4-HMAC-SHA256 Credential=${KEY_ID}/\\d{8}/us-east-1/ses/aws4_request, SignedHeaders=content-type;host;x-amz-date;x-amz-security-token, Signature=[0-9a-f]{64}$`));
  assert.equal(req.headers["x-amz-security-token"], TOKEN);
  assert.equal(req.body.FromEmailAddress, "CronWatch <contact@example.com>");
  assert.deepEqual(req.body.Destination, { ToAddresses: ["owner@example.com"] });
  assert.deepEqual(req.body.ReplyToAddresses, ["ada@example.com"]);
  assert.equal(req.body.Content.Simple.Subject.Data, "cronwatch.dev contact: Ada Lovelace");
  const text = req.body.Content.Simple.Body.Text.Data;
  for (const part of ["Name: Ada Lovelace", "Email: ada@example.com", "IP: 203.0.113.9", "User agent: TestBrowser/1.0", "Hello.\nIt works."]) assert.ok(text.includes(part), part);
  assert.match(text, /Time: \d{4}-\d{2}-\d{2}T/);
  const line = await nextLog();
  assert.equal(line.outcome, "sent");
  assert.equal(line.ip, "203.0.113.9");
  assert.ok(!JSON.stringify(line).includes("Hello"), "the message is not logged");
  assert.ok(!JSON.stringify(line).includes("ada@example.com"), "the address is not logged");
});

test("a form sent without the timer (no script) still goes", async () => {
  const r = await post(form({ t: "" }));
  assert.equal(r.location, "/contact/sent/");
  assert.equal(requests.length, 1);
  await nextLog();
});

test("a filled honeypot is dropped quietly: it looks sent, but nothing is", async () => {
  const r = await post(form({ website: "http://spam.example" }));
  assert.equal(r.status, 303);
  assert.equal(r.location, "/contact/sent/");
  assert.equal(requests.length, 0);
  assert.deepEqual({ ...(await nextLog()), time: 0 }, { time: 0, outcome: "dropped", reason: "honeypot", ip: "203.0.113.9" });
});

test("a form sent within three seconds of loading is turned away", async () => {
  const r = await post(form({ t: "1200" }));
  assert.equal(r.location, "/contact/error/");
  assert.equal(requests.length, 0);
  assert.equal((await nextLog()).reason, "too-fast");
  const bad = await post(form({ t: "soon" }));
  assert.equal(bad.location, "/contact/error/");
  assert.equal((await nextLog()).reason, "bad-timer");
});

test("an oversized body is refused, by length or by what arrives", async () => {
  const big = form({ message: "x".repeat(17 * 1024) });
  const r = await post(big);
  assert.equal(r.status, 303);
  assert.equal(r.location, "/contact/error/");
  assert.equal((await nextLog()).reason, "too-large");
  // Chunked, with no Content-Length to go on.
  const stream = new ReadableStream({ start(c) { c.enqueue(new TextEncoder().encode(big)); c.close(); } });
  const res = await fetch(`${base}/contact`, { method: "POST", body: stream, duplex: "half", redirect: "manual", headers: { "content-type": "application/x-www-form-urlencoded" } });
  await res.text();
  assert.equal(res.headers.get("location"), "/contact/error/");
  assert.equal((await nextLog()).reason, "too-large");
  assert.equal(requests.length, 0);
});

test("missing or overlong fields are turned away", async () => {
  for (const [fields, reason] of [
    [{ name: "" }, "bad-name"], [{ name: "   " }, "bad-name"], [{ name: "n".repeat(201) }, "bad-name"],
    [{ message: "" }, "bad-message"], [{ message: "m".repeat(5001) }, "bad-message"],
  ]) {
    const r = await post(form(fields));
    assert.equal(r.location, "/contact/error/", reason);
    assert.equal((await nextLog()).reason, reason);
  }
  assert.equal(requests.length, 0);
});

test("a bad email address is turned away", async () => {
  for (const email of ["", "ada", "ada@", "@example.com", "ada@example", "ada @example.com", "Ada <ada@example.com>", "ada@example.com, eve@example.com", `${"a".repeat(310)}@example.com`]) {
    const r = await post(form({ email }));
    assert.equal(r.location, "/contact/error/", email);
    assert.equal((await nextLog()).reason, "bad-email");
  }
  assert.equal(requests.length, 0);
});

test("header injection: line breaks never reach a header", async () => {
  for (const email of ["ada@example.com\r\nBcc: eve@example.com", "ada@example.com\nBcc: eve@example.com", "ada@example.com\u2028Bcc: eve@example.com"]) {
    const r = await post(form({ email }));
    assert.equal(r.location, "/contact/error/");
    assert.equal((await nextLog()).reason, "bad-email");
  }
  assert.equal(requests.length, 0);
  // A name is allowed to be odd, but it reaches the subject on one line.
  const r = await post(form({ name: "Ada\r\nBcc: eve@example.com\u0000" }), { headers: { "user-agent": "Evil\tAgent" } });
  assert.equal(r.location, "/contact/sent/");
  assert.equal(requests.length, 1);
  const subject = requests[0].body.Content.Simple.Subject.Data;
  assert.equal(subject, "cronwatch.dev contact: Ada Bcc: eve@example.com");
  assert.ok(!/[\r\n\u0000]/.test(subject));
  assert.ok(requests[0].body.Content.Simple.Body.Text.Data.includes("User agent: Evil Agent"));
  assert.deepEqual(requests[0].body.ReplyToAddresses, ["ada@example.com"]);
  await nextLog();
});

test("only POST /contact with a urlencoded form is accepted", async () => {
  const get = await post(null, { method: "GET" });
  assert.equal(get.status, 405);
  assert.equal(get.headers.get("allow"), "POST");
  assert.equal((await post(form({}), { method: "PUT" })).status, 405);
  assert.equal((await post(form({}), { path: "/other" })).status, 404);
  assert.equal((await post(form({}), { path: "/contact/" })).status, 404);
  assert.equal((await post(JSON.stringify({ name: "a" }), { type: "application/json" })).status, 415);
  assert.equal((await post(form({}), { type: "multipart/form-data; boundary=x" })).status, 415);
  assert.equal((await post(form({}), { type: "text/plain" })).status, 415);
  assert.equal((await post(form({}), { type: "application/x-www-form-urlencoded; charset=UTF-8" })).location, "/contact/sent/");
  await nextLog();
  assert.equal(requests.length, 1);
});

test("an SES failure redirects to the error page and logs no credential", async () => {
  sesStatus = 403;
  const r = await post(form({}));
  assert.equal(r.location, "/contact/error/");
  const line = await nextLog();
  assert.equal(line.outcome, "failed");
  assert.equal(line.reason, "ses-403-SignatureDoesNotMatch");
});

test("no credential appears in any response or log line", async () => {
  sesStatus = 500;
  const r = await post(form({}));
  await nextLog();
  for (const secret of [KEY_ID, SECRET, TOKEN]) {
    assert.ok(!output.includes(secret), "log");
    assert.ok(!r.text.includes(secret) && ![...r.headers.values()].some((v) => v.includes(secret)), "response");
  }
});

/* ---- Start-up ---- */

test("it refuses to start without its configuration, naming what is missing and nothing else", async () => {
  const s = start({ AWS_ACCESS_KEY_ID: KEY_ID, CONTACT_TO: "owner@example.com", CONTACT_PORT: "0" });
  const code = await new Promise((resolve) => s.proc.on("exit", resolve));
  assert.equal(code, 1);
  assert.match(s.output(), /missing required environment variables: AWS_SECRET_ACCESS_KEY, CONTACT_FROM/);
  assert.ok(!s.output().includes(KEY_ID));
});

test("readConfig checks the region, the addresses and the test endpoint", () => {
  const env = { AWS_ACCESS_KEY_ID: KEY_ID, AWS_SECRET_ACCESS_KEY: SECRET, CONTACT_FROM: "a@example.com", CONTACT_TO: "b@example.com" };
  const c = readConfig(env);
  assert.equal(c.region, "us-east-1");
  assert.equal(c.port, 3790);
  assert.equal(c.sesUrl, "https://email.us-east-1.amazonaws.com/v2/email/outbound-emails");
  assert.equal(readConfig({ ...env, AWS_REGION: "eu-west-1" }).sesUrl, "https://email.eu-west-1.amazonaws.com/v2/email/outbound-emails");
  assert.throws(() => readConfig({ ...env, AWS_REGION: "evil.example/" }), /AWS_REGION/);
  assert.throws(() => readConfig({ ...env, CONTACT_TO: "b@example.com\nBcc: c@example.com" }), /one line/);
  assert.throws(() => readConfig({ ...env, CONTACT_SES_URL: "https://attacker.example/" }), /tests/);
  assert.throws(() => readConfig({ ...env, CONTACT_PORT: "http" }), /port/);
  for (const e of [() => readConfig({}), () => readConfig({ ...env, AWS_REGION: "x y" })]) {
    try { e(); } catch (err) { assert.ok(!err.message.includes(SECRET)); }
  }
});

test("checkForm and headerSafe", () => {
  assert.equal(checkForm(new URLSearchParams(form({ message: "a\r\nb" }))).message, "a\nb");
  assert.equal(checkForm(new URLSearchParams({ name: "x", email: "x@example.com", message: "m" })).ok, true, "no timer, no honeypot field");
  assert.equal(headerSafe("a\r\n\tb\u2028c"), "a b c");
});

/* ---- Signing ---- */

// Cases from the AWS Signature Version 4 test suite, as in packages/sdk/test/sigv4.test.ts.
const now = Date.UTC(2015, 7, 30, 12, 36, 0);
const creds = { accessKeyId: "AKIDEXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY" };
const scope = "Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request";
for (const c of [
  { name: "get-vanilla", method: "GET", url: "https://example.amazonaws.com/", headers: {}, sig: "SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31" },
  { name: "post-vanilla", method: "POST", url: "https://example.amazonaws.com/", headers: {}, sig: "SignedHeaders=host;x-amz-date, Signature=5da7c1a2acd57cee7505fc6676e4e544621c30862966e37dddb68e92efbe5d6b" },
  { name: "get-vanilla-query-order-key-case", method: "GET", url: "https://example.amazonaws.com/?Param2=value2&Param1=value1", headers: {}, sig: "SignedHeaders=host;x-amz-date, Signature=b97d918cfa904a5beff61c982a1b6f458b799221646efd99d3219ec94cdf2500" },
  { name: "post-header-value-case", method: "POST", url: "https://example.amazonaws.com/", headers: { "My-Header1": "VALUE1" }, sig: "SignedHeaders=host;my-header1;x-amz-date, Signature=cdbc9802e29d2942e5e10b5bccfdd67c5f22c7c4e8ae67b53629efa58b974b7d" },
]) {
  test(`signV4 matches the AWS test suite: ${c.name}`, () => {
    const h = signV4({ method: c.method, url: c.url, headers: c.headers, body: "", region: "us-east-1", service: "service", now }, creds);
    assert.equal(h.authorization, `AWS4-HMAC-SHA256 ${scope}, ${c.sig}`);
    assert.equal(h["x-amz-date"], "20150830T123600Z");
    assert.equal(h.host, undefined);
  });
}
