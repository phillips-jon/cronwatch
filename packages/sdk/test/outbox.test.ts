import assert from "node:assert/strict";
import { test } from "node:test";
import { cronwatch, memory } from "../src/index.js";
import type { Alert, AlertChannel, Store } from "../src/index.js";
import { SEND_LEASE_MS } from "../src/evaluate.js";
import { capture, clock, MIN, settle, T0 } from "./helpers.js";

/**
 * A store for a process that is about to die: once `kill()` is called,
 * nothing it asks of the store ever completes, as when the process is gone.
 */
function mortal(store: Store) {
  let dead = false;
  const wrapped = new Proxy(store, {
    get(target, prop, receiver) {
      const value = Reflect.get(target, prop, receiver);
      if (typeof value !== "function") return value;
      return (...args: unknown[]) => (dead ? new Promise(() => {}) : value.apply(target, args));
    },
  });
  return { store: wrapped, kill: () => { dead = true; } };
}

/** A channel whose sends wait for `release()`, and which says when one has started. */
function held() {
  let release!: () => void;
  let entered!: () => void;
  const gate = new Promise<void>((r) => { release = r; });
  const sending = new Promise<void>((r) => { entered = r; });
  const sent: Alert[] = [];
  const channel: AlertChannel = { name: "held", send: async (alert) => { entered(); await gate; sent.push(alert); } };
  return { channel, sending, release, sent };
}

test("the write that opens a condition holds its alert, so a process that dies before sending it does not lose it", async () => {
  const c = clock();
  const shared = memory();
  const { store, kill } = mortal(shared);
  let triaging!: () => void;
  const triaged = new Promise<void>((r) => { triaging = r; });
  // The process dies while its triage call is out: no channel was ever called.
  const dying = cronwatch({ store, now: c.now, alerts: [capture()], cronSecret: null, triage: async () => { kill(); triaging(); return new Promise(() => {}); } });
  void dying.run("nightly", async () => { throw new Error("disk full"); }).catch(() => {});
  await triaged;
  const state = (await shared.getState("nightly"))!;
  assert.equal(state.open.failed, T0);
  assert.deepEqual(state.sending!.map((entry) => [entry.alert.type, entry.alert.at, entry.until]), [["failed", T0, T0 + SEND_LEASE_MS]]);
  assert.equal(state.sending![0]!.alert.triage, undefined, "triage is made at send time, never stored here");
  assert.deepEqual(state.undelivered, []);

  // Another process's checks leave it alone while its sender's lease runs.
  const sent = capture();
  const server = cronwatch({ store: shared, now: c.now, alerts: [sent], cronSecret: null, triage: async () => "The disk is full." });
  c.advance(MIN);
  await server.check();
  assert.deepEqual(sent.types(), []);

  // Once it has run out, the next check sends it, triaged, once.
  c.set(T0 + SEND_LEASE_MS + 1);
  const result = await server.check();
  assert.deepEqual(result.alerts.map((a) => a.type), ["failed"]);
  assert.deepEqual(sent.alerts.map((a) => [a.type, a.at, a.triage]), [["failed", T0, "The disk is full."]]);
  const after = (await shared.getState("nightly"))!;
  assert.equal(after.sending, undefined, "the key goes once nothing is being sent");
  assert.deepEqual(after.undelivered, []);
  await server.check();
  await assert.rejects(server.run("nightly", async () => { throw new Error("again"); }));
  assert.deepEqual(sent.types(), ["failed"], "the condition still alerts once");
});

test("an alert a channel took just before its process died is sent again after the lease: at least once", async () => {
  const c = clock();
  const shared = memory();
  const { store, kill } = mortal(shared);
  const first = capture();
  // Accepted, then the process is gone before it records that.
  const dying = cronwatch({ store, now: c.now, alerts: [{ name: "first", send: async (alert) => { await first.send(alert); kill(); } }], cronSecret: null });
  void dying.run("nightly", async () => { throw new Error("x"); }).catch(() => {});
  await settle();
  assert.deepEqual(first.types(), ["failed"]);
  const sent = capture();
  const server = cronwatch({ store: shared, now: c.now, alerts: [sent], cronSecret: null });
  c.set(T0 + SEND_LEASE_MS + 1);
  await server.check();
  assert.deepEqual(sent.types(), ["failed"], "sent a second time: the one duplicate a crash can cause");
});

test("while an alert is being sent, no check anywhere sends it too", async () => {
  const c = clock();
  const shared = memory();
  const { channel, sending, release, sent } = held();
  const worker = cronwatch({ store: shared, now: c.now, alerts: [channel], cronSecret: null });
  const other = capture();
  const server = cronwatch({ store: shared, now: c.now, alerts: [other], cronSecret: null });
  const run = worker.run("nightly", async () => { throw new Error("x"); }).catch(() => {});
  await sending;
  c.advance(MIN);
  await server.check();
  // The sending process's own check, too.
  const ownCheck = worker.check();
  await settle();
  release();
  await Promise.all([run, ownCheck]);
  assert.deepEqual(sent.map((a) => a.type), ["failed"]);
  assert.deepEqual(other.types(), []);
  const state = (await shared.getState("nightly"))!;
  assert.equal(state.sending, undefined);
  assert.deepEqual(state.undelivered, []);
  assert.equal(state.lastAlertAt, T0, "the time the run was judged, as before");
  c.set(T0 + SEND_LEASE_MS + MIN);
  await server.check();
  await worker.check();
  assert.deepEqual(other.types(), []);
  assert.deepEqual(sent.map((a) => a.type), ["failed"]);
});

test("an alert no channel took moves from the outbox to the retry queue, with its triage", async () => {
  const c = clock();
  const shared = memory();
  const down: AlertChannel = { name: "down", send: async () => { throw new Error("down"); } };
  const cw = cronwatch({ store: shared, now: c.now, alerts: [down], cronSecret: null, onError: () => {}, triage: async () => "Look at the disk." });
  await assert.rejects(cw.run("nightly", async () => { throw new Error("x"); }));
  const state = (await shared.getState("nightly"))!;
  assert.equal(state.sending, undefined);
  assert.deepEqual(state.undelivered!.map((a) => [a.type, a.triage]), [["failed", "Look at the disk."]]);
});

test("a process that queues its alerts for a check elsewhere writes them with the state that opens the condition", async () => {
  const c = clock();
  const shared = memory();
  let writes = 0;
  const counting: Store = { ...shared, compareAndSetState: async (state, version) => { writes++; return shared.compareAndSetState!(state, version); } };
  const recorder = cronwatch({ store: counting, now: c.now, deliver: "check", cronSecret: null });
  await assert.rejects(recorder.run("backup", async () => { throw new Error("disk full"); }));
  const state = (await shared.getState("backup"))!;
  assert.deepEqual(state.undelivered!.map((a) => a.type), ["failed"]);
  assert.equal(state.sending, undefined);
  assert.equal(writes, 1, "one write: the failure and its alert together");
});
