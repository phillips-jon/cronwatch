import assert from "node:assert/strict";
import { test } from "node:test";
import { cronwatch } from "../src/index.js";
import { OUTPUT_CAP, redactSecrets } from "../src/output.js";
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

test("expect still sees the unredacted output", async () => {
  const cw = cronwatch({ alerts: [capture()], cronSecret: null });
  await cw.run("e", { expect: "token=abc" }, async (job) => { job.log("token=abc"); });
  const [run] = await cw.runs("e");
  assert.equal(run!.status, "ok");
  assert.equal(run!.output, "token=[redacted]");
});

test("errors are capped like logged output", async () => {
  const cw = cronwatch({ alerts: [capture()], cronSecret: null });
  await assert.rejects(cw.run("big", async () => { throw new Error("x".repeat(100_000)); }));
  assert.ok((await cw.runs("big"))[0]!.error!.length <= OUTPUT_CAP + 30);
});
