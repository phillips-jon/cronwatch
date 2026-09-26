import assert from "node:assert/strict";
import { test } from "node:test";
import type Anthropic from "@anthropic-ai/sdk";
import { discord } from "../src/alerts/discord.js";
import { slack } from "../src/alerts/slack.js";
import { webhook } from "../src/alerts/webhook.js";
import { composeAlert } from "../src/format.js";
import { anthropic } from "../src/triage/anthropic.js";
import type { Alert, Run } from "../src/types.js";
import { T0 } from "./helpers.js";

const run: Run = {
  id: "r1", job: "j", status: "failed", startedAt: T0, finishedAt: T0 + 1000, durationMs: 1000,
  error: "Error: boom", output: "before\n```\n@everyone <!channel> [click](https://evil.example)", metrics: {}, trigger: "run",
};

function alert(extra: Partial<Alert> = {}): Alert {
  return { ...composeAlert({ type: "failed", run, details: { consecutiveFailures: 1, threshold: 1 } }, { name: "j" }, T0 + 2000), ...extra } as Alert;
}

/** Replaces fetch for one test, recording each request. */
function stubFetch(t: { after(fn: () => void): void }, status = 200) {
  const calls: { url: string; init: RequestInit; body: any }[] = [];
  const original = globalThis.fetch;
  globalThis.fetch = (async (url: string, init: RequestInit) => {
    calls.push({ url, init, body: JSON.parse(String(init.body)) });
    return new Response(status < 400 ? "" : "nope", { status });
  }) as typeof fetch;
  t.after(() => { globalThis.fetch = original; });
  return calls;
}

test("discord keeps job output inside its code block and pings no one", async (t) => {
  const calls = stubFetch(t);
  await discord({ webhookUrl: "https://discord.example/api/webhooks/1/secret" }).send(alert({ triage: "See [the docs](https://evil.example) *now*" }));
  const { init, body } = calls[0]!;
  assert.ok(init.signal instanceof AbortSignal, "the request can time out");
  assert.deepEqual(body.allowed_mentions, { parse: [] });
  const description: string = body.embeds[0].description;
  assert.equal(description.match(/```/g)!.length, 2, "only the block's own fences");
  assert.match(description, /\*\*Triage:\*\* See \\\[the docs\\\]\\\(https:\/\/evil\.example\\\) \\\*now\\\*/);
});

test("slack escapes control characters and fences, in the blocks and the fallback text", async (t) => {
  const calls = stubFetch(t);
  await slack({ webhookUrl: "https://hooks.slack.example/T/B/secret" }).send(alert());
  const { init, body } = calls[0]!;
  assert.ok(init.signal instanceof AbortSignal);
  assert.doesNotMatch(body.text, /<!channel>/);
  const block: string = body.blocks[1].text.text;
  assert.equal(block.match(/```/g)!.length, 2);
  assert.match(block, /&lt;!channel&gt;/);
});

test("webhook failures name the origin, not the secret path", async (t) => {
  const calls = stubFetch(t, 500);
  await assert.rejects(
    webhook({ url: "https://hooks.example.com/services/s3cret-token?key=abc" }).send(alert()),
    (error: Error) => error.message === "Webhook https://hooks.example.com answered 500",
  );
  assert.ok(calls[0]!.init.signal instanceof AbortSignal);
});

test("anthropic triage makes one attempt, bounded in time, that the client can abort", async () => {
  let seen: { signal?: AbortSignal; timeout?: number; maxRetries?: number } | undefined;
  const client = {
    beta: {
      messages: {
        create: async (_params: unknown, options: typeof seen) => {
          seen = options;
          return { stop_reason: "end_turn", content: [{ type: "text", text: "The database was down." }] };
        },
      },
    },
  } as unknown as Anthropic;
  const controller = new AbortController();
  const diagnosis = await anthropic({ client })({ alert: alert(), recentRuns: [], signal: controller.signal });
  assert.equal(diagnosis, "The database was down.");
  assert.equal(seen!.signal, controller.signal);
  assert.equal(seen!.maxRetries, 0);
  assert.ok(seen!.timeout! < 25_000);
});
