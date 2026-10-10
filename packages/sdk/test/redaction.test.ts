import assert from "node:assert/strict";
import { test } from "node:test";
import { cronwatch } from "../src/index.js";
import { OUTPUT_CAP, REDACT_EDGE, redactAndCap, redactSecrets } from "../src/output.js";
import { capture } from "./helpers.js";

test("secrets are redacted from output and errors before they are stored or alerted", async () => {
  const alerts = capture();
  const cw = cronwatch({ alerts: [alerts], cronSecret: null });
  await assert.rejects(cw.run("leaky", async (job) => {
    job.log("DB_PASSWORD=hunter2 tokens: 1200");
    throw new Error("connect ECONNREFUSED postgres://app:s3cr3t@10.0.0.12:5432/db");
  }));
  const [run] = await cw.runs("leaky");
  assert.equal(run!.output, "DB_PASSWORD=[redacted] tokens: 1200");
  assert.match(run!.error!, /postgres:\/\/app:\[redacted\]@10\.0\.0\.12/);
  assert.equal(alerts.alerts.length, 1);
  assert.doesNotMatch(JSON.stringify(alerts.alerts), /hunter2|s3cr3t/);

  const raw = cronwatch({ alerts: [capture()], cronSecret: null, redact: false });
  await raw.run("raw", async (job) => { job.log("password=kept"); });
  assert.equal((await raw.runs("raw"))[0]!.output, "password=kept");

  assert.equal(redactSecrets("key AKIAIOSFODNN7EXAMPLE and ghp_" + "a".repeat(36)), "key [redacted] and [redacted]");
  assert.equal(redactSecrets("Authorization: Bearer abcdefgh12345"), "Authorization: Bearer [redacted]");
  assert.equal(redactSecrets("max_tokens: 800"), "max_tokens: 800");
});

test("a quoted secret is blanked to its closing quote, in single or double quotes", () => {
  assert.equal(redactSecrets("SLACK_TOKEN='xoxb-123'"), "SLACK_TOKEN='[redacted]'");
  assert.equal(redactSecrets('PASSWORD = "two words here"'), 'PASSWORD = "[redacted]"');
  assert.equal(redactSecrets('{"client_secret": "abc def", "other": "x"}'), '{"client_secret": "[redacted]", "other": "x"}');
  assert.equal(redactSecrets('password="a" user="b"'), 'password="[redacted]" user="b"');
  assert.equal(redactSecrets('password="unterminated'), "password=[redacted]");
});

test("expect still sees the unredacted output", async () => {
  const cw = cronwatch({ alerts: [capture()], cronSecret: null });
  await cw.run("e", { expect: "token=abc" }, async (job) => { job.log("token=abc"); });
  const [run] = await cw.runs("e");
  assert.equal(run!.status, "ok");
  assert.equal(run!.output, "token=[redacted]");
});

test("the added secret shapes are blanked", () => {
  const cases: [string, string][] = [
    [':password=>"hunter2"', ':password=>"[redacted]"'],
    ["{:api_key => 'abc', user: 1}", "{:api_key => '[redacted]', user: 1}"],
    ["Authorization: Basic dXNlcjpwYXNz", "Authorization: Basic [redacted]"],
    ['{"Authorization": "Token abc123", "x": 1}', '{"Authorization": "Token [redacted]", "x": 1}'],
    ["-----BEGIN RSA PRIVATE KEY-----\nMIIEow\nIBAAK==\n-----END RSA PRIVATE KEY-----\nafter", "[redacted]\nafter"],
    ["-----BEGIN PRIVATE KEY-----\nMIIE\nabc", "[redacted]"],
    ["jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc_def-123 done", "jwt [redacted] done"],
    ["https://hooks.slack.com/services/T0/B0/xyz ok", "https://hooks.slack.com/services/[redacted] ok"],
    ["https://discord.com/api/webhooks/123/abc-def", "https://discord.com/api/webhooks/[redacted]"],
    ["key AI" + "za" + "Sy".repeat(17) + "A", "key [redacted]"],
    ["wh" + "sec_" + "abcd1234".repeat(3), "[redacted]"],
    ["postgres://user:p@ss@host/db", "postgres://user:[redacted]@host/db"],
  ];
  for (const [input, expected] of cases) assert.equal(redactSecrets(input), expected, input);
});

test("adversarial 16 KB lines redact in linear time", () => {
  const shapes = [
    "password", "token-", "secret_", "a-", "password_x-", "-token", "tokens-", 'token"  ', "token  =", 'password="', "x=>", "=>",
    "authorization: ", "authorization: basic ", "Authorization-", "a://", "a://x:", "postgres://u:", "a://" + "b".repeat(250) + ":",
    "a://b:" + "c".repeat(250), "https://u:@@@", "@", ":", "Bearer ", "eyJ", "eyJa.", "eyJaaaa.aaaa", "eyJ" + "a".repeat(4090) + ".",
    "-----BEGIN PRIVATE KEY-----", "-----BEGIN PRIVATE KEY-----" + "a".repeat(100), "-----BEGIN A B C ", "-----BEGIN PRIVATE KEY----------",
    "hooks.slack.com/services/", "x.discord.com/api/webhooks/", "AI" + "za", "wh" + "sec_", "-", " ",
  ];
  let worst = 0;
  let slowest = "";
  for (const shape of shapes) {
    const line = shape.repeat(Math.ceil(16_384 / shape.length)).slice(0, 16_384);
    const started = performance.now();
    redactSecrets(line);
    redactSecrets(line + "!");
    const took = performance.now() - started;
    if (took > worst) [worst, slowest] = [took, shape.slice(0, 30)];
  }
  assert.ok(worst < 250, `${JSON.stringify(slowest)} took ${worst.toFixed(1)}ms`);
});

test("NUL characters never reach the store", async () => {
  const cw = cronwatch({ alerts: [capture()], cronSecret: null });
  await assert.rejects(cw.run("nul", async (job) => { job.log("a\u0000b"); throw new Error("bad\u0000byte"); }));
  const [run] = await cw.runs("nul");
  assert.equal(run!.output, "ab");
  assert.match(run!.error!, /^Error: badbyte/);
  await cw.run("nul", async () => "x\u0000y");
  assert.equal((await cw.runs("nul"))[0]!.output, "xy");
  const custom = cronwatch({ alerts: [capture()], cronSecret: null, redact: (text) => `${text}\u0000` });
  await custom.run("nul", async (job) => { job.log("z"); });
  assert.equal((await custom.runs("nul"))[0]!.output, "z", "even a custom redact cannot put one back");
});

test("a redact that throws falls back to the default and is reported", async () => {
  const errors: [unknown, string][] = [];
  const cw = cronwatch({ alerts: [capture()], cronSecret: null, redact: () => { throw new Error("redactor broke"); }, onError: (e, where) => errors.push([e, where]) });
  await cw.run("r", async (job) => { job.log("password=hunter2"); });
  const [run] = await cw.runs("r");
  assert.equal(run!.status, "ok");
  assert.equal(run!.output, "password=[redacted]");
  assert.deepEqual(errors.map(([, where]) => where), ["redact"]);
  assert.match((errors[0]![0] as Error).message, /redactor broke/);

  const odd = cronwatch({ alerts: [capture()], cronSecret: null, redact: () => 42 as unknown as string, onError: () => { throw new Error("and onError too"); } });
  await assert.rejects(odd.run("r", async () => { throw new Error("token=abc"); }), /token=abc/);
  const [failed] = await odd.runs("r");
  assert.equal(failed!.status, "failed");
  assert.match(failed!.error!, /token=\[redacted\]/);
});

test("errors are capped like logged output", async () => {
  const cw = cronwatch({ alerts: [capture()], cronSecret: null });
  await assert.rejects(cw.run("big", async () => { throw new Error("x".repeat(100_000)); }));
  assert.ok((await cw.runs("big"))[0]!.error!.length <= OUTPUT_CAP + 30);
});

test("a secret split by the 16 KB cut is redacted whole: redaction comes before the cap", async () => {
  const pem = "-----BEGIN PRIVATE KEY-----\n" + Array.from({ length: 25 }, (_, i) => `${"QUJD".repeat(15)}${String(i).padStart(4, "0")}`).join("\n") + "\n-----END PRIVATE KEY-----";
  const bearer = "Authorization: Bearer opaqueTOKENvalue1234567890";
  const cw = cronwatch({ alerts: [capture()], cronSecret: null });
  // The cut lands inside the key's body, and in a second run just after "Bear".
  await cw.run("pem", async (job) => { job.log("x".repeat(OUTPUT_CAP)); job.log(pem.slice(0, 900)); job.log(pem.slice(900)); job.log("done"); });
  const pemOutput = (await cw.runs("pem"))[0]!.output!;
  assert.doesNotMatch(pemOutput, /QUJD/);
  assert.match(pemOutput, /\[redacted\]\ndone$/);
  const tail = "y".repeat(OUTPUT_CAP - 30);
  await cw.run("bearer", async () => bearer + "\n" + tail);
  const bearerOutput = (await cw.runs("bearer"))[0]!.output!;
  assert.doesNotMatch(bearerOutput, /opaqueTOKEN/);
  assert.ok(bearerOutput.length <= OUTPUT_CAP + "[earlier output trimmed]\n".length);

  // Errors, recorded runs, and flushed lines the same way.
  await assert.rejects(cw.run("thrown", async () => { throw new Error(`${"e".repeat(OUTPUT_CAP)} ${bearer} ${"z".repeat(OUTPUT_CAP - 40)}`); }));
  assert.doesNotMatch((await cw.runs("thrown"))[0]!.error!, /opaqueTOKEN/);
  cw.job("imported");
  await cw.recordRun({ id: "i1", job: "imported", status: "ok", startedAt: 1, finishedAt: 2, durationMs: 1, error: null, output: `${bearer}\n${tail}`, metrics: {}, trigger: "source" });
  assert.doesNotMatch((await cw.getRun("i1"))!.output!, /opaqueTOKEN/);
  const handle = await cw.job("flushed").start();
  handle.log(bearer);
  handle.log(tail);
  await handle.flush();
  assert.doesNotMatch((await cw.getRun(handle.id))!.output!, /opaqueTOKEN/);
  await handle.finish();
  assert.doesNotMatch((await cw.getRun(handle.id))!.output!, /opaqueTOKEN/);
});

test("text past the redaction window never keeps what came right after its cut", () => {
  // The window starts part way into a key's body, whose header is before it:
  // the body's rest cannot be told from text, so it is never kept.
  const body = "QUJD".repeat(4000);
  const text = "-----BEGIN PRIVATE KEY-----\n" + body + "\n" + "k".repeat(OUTPUT_CAP + REDACT_EDGE - 8000);
  const kept = redactAndCap(text, redactSecrets);
  assert.ok(kept.startsWith("[earlier output trimmed]\n"));
  assert.equal(kept.length, "[earlier output trimmed]\n".length + OUTPUT_CAP);
  assert.doesNotMatch(kept, /QUJD/);

  // A redaction that shrinks the window cannot pull its first units into view.
  const shrinking = (t: string) => t.replace(/s{100}/g, "");
  const shrunk = redactAndCap("QUJD".repeat(100) + "s".repeat(OUTPUT_CAP + REDACT_EDGE), shrinking);
  assert.equal(shrunk, "[earlier output trimmed]\n");

  // Short text is redacted whole, then capped as before; NULs go either side of redact.
  assert.equal(redactAndCap("password=x", redactSecrets), "password=[redacted]");
  assert.equal(redactAndCap("a\u0000b", (t) => `${t}\u0000`), "ab");
  assert.equal(redactAndCap("x".repeat(OUTPUT_CAP + 5), redactSecrets), "[earlier output trimmed]\n" + "x".repeat(OUTPUT_CAP));
});
