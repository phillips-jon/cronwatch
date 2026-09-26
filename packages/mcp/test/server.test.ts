import assert from "node:assert/strict";
import { test } from "node:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { createServer } from "../src/server.js";

/** A fake of the JSON API @cronwatch/sdk mounts, enough to exercise every tool. */
function fakeApi() {
  const calls: string[] = [];
  const job = {
    name: "nightly", definition: { name: "nightly", schedule: "0 2 * * *" }, health: "failing", open: ["failed"],
    lastRun: { id: "r2", status: "failed", startedAt: 1_700_000_000_000, finishedAt: 1_700_000_001_000, durationMs: 1000, error: "Error: db down\n  at x", output: "step 1\nstep 2", metrics: { cost: 0.4 }, trigger: "handler" },
    nextExpectedAt: 1_700_050_000_000, consecutiveFailures: 1, silencedUntil: null, stats: { runs: 2, okRate: 0.5, p50Ms: 900, p95Ms: 1000 },
  };
  const fetchFn: typeof fetch = async (input, init) => {
    const url = new URL(String(input));
    calls.push(`${init?.method ?? "GET"} ${url.pathname}${url.search} auth=${(init?.headers as Record<string, string>)?.authorization ?? ""}`);
    const p = url.pathname;
    const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { "content-type": "application/json" } });
    if (p === "/cronwatch/api/jobs") return json({ ok: true, jobs: [job] });
    if (p === "/cronwatch/api/jobs/nightly") return json({ ok: true, job, runs: [job.lastRun] });
    if (p === "/cronwatch/api/jobs/nightly/silence") return json({ ok: true, state: { silencedUntil: 1_700_100_000_000 } });
    if (p === "/cronwatch/api/check") return json({ ok: true, checkedAt: 1_700_000_000_000, jobs: [job], alerts: [{ type: "missed", job: "nightly", title: "x" }], pruned: 0 });
    return json({ ok: false, error: "No such job" }, 404);
  };
  return { fetchFn, calls };
}

async function connected() {
  const api = fakeApi();
  const server = createServer({ baseUrl: "https://app.test/cronwatch/", token: "tok", fetch: api.fetchFn });
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  await server.connect(serverTransport);
  const client = new Client({ name: "test", version: "0" });
  await client.connect(clientTransport);
  return { client, api, close: async () => { await client.close(); await server.close(); } };
}

test("lists its tools", async () => {
  const { client, close } = await connected();
  const { tools } = await client.listTools();
  assert.deepEqual(tools.map((t) => t.name).sort(), ["forget_job", "get_job", "get_setup_guide", "list_jobs", "run_check", "silence_job", "unsilence_job"]);
  await close();
});

test("tools call the API with the bearer token and summarise", async () => {
  const { client, api, close } = await connected();
  const list = await client.callTool({ name: "list_jobs", arguments: {} });
  const listText = (list.content as { text: string }[])[0]!.text;
  assert.match(listText, /1 job, 1 needing attention/);
  assert.match(listText, /nightly: failing \(open: failed\)/);
  assert.equal(api.calls[0], "GET /cronwatch/api/jobs auth=Bearer tok");

  const job = await client.callTool({ name: "get_job", arguments: { name: "nightly", runs: 5 } });
  const jobText = (job.content as { text: string }[])[0]!.text;
  assert.match(jobText, /db down/);
  assert.match(jobText, /step 2/);
  assert.match(jobText, /"schedule": "0 2 \* \* \*"/);
  assert.equal(api.calls[1], "GET /cronwatch/api/jobs/nightly?runs=5 auth=Bearer tok");

  const check = await client.callTool({ name: "run_check", arguments: {} });
  assert.match((check.content as { text: string }[])[0]!.text, /Alerts sent: nightly missed/);

  const silence = await client.callTool({ name: "silence_job", arguments: { name: "nightly", for: "2h" } });
  assert.match((silence.content as { text: string }[])[0]!.text, /silenced until 2023-11-16/);

  const missing = await client.callTool({ name: "get_job", arguments: { name: "nope" } });
  assert.equal(missing.isError, true);
  assert.match((missing.content as { text: string }[])[0]!.text, /404.*No such job/);

  const guide = await client.callTool({ name: "get_setup_guide", arguments: {} });
  assert.match((guide.content as { text: string }[])[0]!.text, /cw\.job\("nightly-report"/);
  await close();
});
