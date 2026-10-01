// The webhook payload against its published JSON Schema
// (site/src/schemas/webhook/1.json, served at cronwatch.dev/schemas/webhook/1.json):
// every alert the channels fixture sends, and every alert type, validates,
// and the schema names every field the payload carries. The validator is
// the small part of JSON Schema the file uses.
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { composeAlert } from "../src/format.js";
import { webhook } from "../src/alerts/webhook.js";
import type { Alert, AlertDraft, Run } from "../src/types.js";

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "..", "..");
type Schema = Record<string, unknown>;
const schema = JSON.parse(readFileSync(path.join(root, "site", "src", "schemas", "webhook", "1.json"), "utf8")) as Schema;

function typeOf(value: unknown): string {
  if (value === null) return "null";
  if (Array.isArray(value)) return "array";
  if (typeof value === "number") return Number.isInteger(value) ? "integer" : "number";
  return typeof value;
}

/** The problems with `value` against `s`, as paths; empty when it is valid. */
function validate(value: unknown, s: Schema, at = "$"): string[] {
  if (typeof s.$ref === "string") {
    const name = s.$ref.replace("#/$defs/", "");
    return validate(value, (schema.$defs as Record<string, Schema>)[name]!, at);
  }
  const errors: string[] = [];
  if (s.type !== undefined) {
    const types = Array.isArray(s.type) ? s.type : [s.type];
    const t = typeOf(value);
    if (!types.includes(t) && !(t === "integer" && types.includes("number"))) errors.push(`${at}: ${t} is not ${types.join(" or ")}`);
  }
  if ("const" in s && JSON.stringify(value) !== JSON.stringify(s.const)) errors.push(`${at}: not ${JSON.stringify(s.const)}`);
  if (Array.isArray(s.enum) && !s.enum.some((e) => JSON.stringify(e) === JSON.stringify(value))) errors.push(`${at}: not one of ${JSON.stringify(s.enum)}`);
  if (typeof s.minimum === "number" && typeof value === "number" && value < s.minimum) errors.push(`${at}: below ${s.minimum}`);
  if (Array.isArray(value)) {
    if (typeof s.minItems === "number" && value.length < s.minItems) errors.push(`${at}: fewer than ${s.minItems} items`);
    if (s.items) value.forEach((item, i) => errors.push(...validate(item, s.items as Schema, `${at}[${i}]`)));
  }
  if (typeOf(value) === "object") {
    const object = value as Record<string, unknown>;
    for (const key of (s.required as string[] | undefined) ?? []) if (!(key in object)) errors.push(`${at}: missing ${key}`);
    const properties = (s.properties ?? {}) as Record<string, Schema>;
    for (const [key, v] of Object.entries(object)) {
      if (properties[key]) errors.push(...validate(v, properties[key]!, `${at}.${key}`));
      else if (s.additionalProperties && typeof s.additionalProperties === "object") errors.push(...validate(v, s.additionalProperties as Schema, `${at}.${key}`));
    }
  }
  if (Array.isArray(s.oneOf)) {
    const passing = s.oneOf.filter((option) => validate(value, option as Schema, at).length === 0).length;
    if (passing !== 1) errors.push(`${at}: matches ${passing} of oneOf`);
  }
  for (const part of (s.allOf as Schema[] | undefined) ?? []) {
    if (part.if && validate(value, part.if as Schema, at).length === 0) errors.push(...validate(value, part.then as Schema, at));
  }
  return errors;
}

/** Every key the payload has at this level is one the schema names, so the schema documents all of it. */
function unnamed(value: unknown, s: Schema, at = "$"): string[] {
  if (typeof s.$ref === "string") return unnamed(value, (schema.$defs as Record<string, Schema>)[s.$ref.replace("#/$defs/", "")]!, at);
  if (typeOf(value) !== "object" || !s.properties) return [];
  const properties = s.properties as Record<string, Schema>;
  return Object.entries(value as Record<string, unknown>).flatMap(([key, v]) => {
    if (!properties[key]) return [`${at}.${key}`];
    const inner = properties[key]!;
    const options = Array.isArray(inner.oneOf) ? (inner.oneOf as Schema[]) : [inner];
    return options.flatMap((option) => unnamed(v, option, `${at}.${key}`));
  });
}

function detailsSchema(type: string): Schema {
  for (const part of schema.allOf as Schema[]) {
    if (validate({ type }, part.if as Schema).length === 0) return ((part.then as Schema).properties as Record<string, Schema>).details!;
  }
  throw new Error(`no details schema for ${type}`);
}

interface Payload { alert: string; secret: string; body: string; signature: string }
const fixture = JSON.parse(readFileSync(path.join(root, "conformance", "channels.json"), "utf8")) as { webhookPayloads: Payload[] };

test("every payload in conformance/channels.json validates, and its signature is the body's HMAC", () => {
  assert.ok(fixture.webhookPayloads.length > 0);
  for (const p of fixture.webhookPayloads) {
    const body = JSON.parse(p.body) as Record<string, unknown>;
    assert.equal(Object.keys(body)[0], "schema", p.alert);
    assert.deepEqual(validate(body, schema), [], p.alert);
    assert.deepEqual(unnamed(body, schema), [], p.alert);
    assert.deepEqual(unnamed(body.details, detailsSchema(body.type as string), "$.details"), [], p.alert);
    assert.equal(p.signature, `sha256=${createHmac("sha256", p.secret).update(p.body).digest("hex")}`, p.alert);
  }
});

test("every alert type, with triage, sent through the channel, validates", async () => {
  const run: Run = { id: "r", job: "j", status: "failed", startedAt: 1_000, finishedAt: 2_500, durationMs: 1_500, error: "Error: x", output: "o", metrics: { cost: 3 }, trigger: "run" };
  const drafts: AlertDraft[] = [
    { type: "missed", run: null, details: { dueAt: 1_000, deadline: 601_000, graceMs: 600_000, lastRunAt: null } },
    { type: "failed", run, details: { consecutiveFailures: 2, threshold: 2 } },
    { type: "stuck", run: { ...run, status: "timeout" }, details: { consecutiveFailures: 1, threshold: 1 } },
    { type: "slow", run: { ...run, status: "ok" }, details: { durationMs: 1_500, thresholdMs: 1_000, basis: "maxDuration" } },
    { type: "over_budget", run: { ...run, status: "ok" }, details: { breaches: [{ metric: "cost", value: 3, limit: 2, basis: "budget" }] } },
    { type: "recovered", run: { ...run, status: "ok" }, details: { after: ["failed", "slow"] } },
    { type: "recovered", run: null, details: { after: ["missed"], reason: "unscheduled", since: 1_000 } },
  ];
  const definition = { name: "j", schedule: "0 2 * * *", timezone: "UTC", grace: "10m", timeout: 60_000, maxDuration: "1s", budget: { cost: 2 }, expect: "done", failuresBeforeAlert: 2, description: "d", tags: ["t"] };
  const sent: string[] = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = (async (_url: string, init: RequestInit) => {
    sent.push(init.body as string);
    return new Response("", { status: 200 });
  }) as typeof fetch;
  try {
    const channel = webhook({ url: "https://hooks.example.com/in" });
    for (const draft of drafts) {
      const alert = composeAlert(draft, definition, 5_000) as Alert;
      alert.triage = draft.type === "recovered" ? undefined : draft.type === "slow" ? null : "Probably the database.";
      await channel.send(alert);
    }
  } finally {
    globalThis.fetch = realFetch;
  }
  assert.equal(sent.length, drafts.length);
  for (const text of sent) {
    const body = JSON.parse(text) as Record<string, unknown>;
    assert.deepEqual(validate(body, schema), [], text);
    assert.deepEqual(unnamed(body, schema), [], text);
    assert.deepEqual(unnamed(body.details, detailsSchema(body.type as string), "$.details"), [], text);
  }
  // And the validator does refuse what it should.
  const bad = JSON.parse(sent[0]!) as Record<string, unknown>;
  assert.notDeepEqual(validate({ ...bad, schema: 2 }, schema), []);
  assert.notDeepEqual(validate({ ...bad, details: { dueAt: "soon" } }, schema), []);
  assert.notDeepEqual(validate({ ...bad, run: { id: "r" } }, schema), []);
});
