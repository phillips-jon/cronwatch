import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import { cronwatch, memory } from "../src/index.js";
import { sqlite } from "../src/stores/sqlite.js";
import type { Store } from "../src/types.js";
import { capture, clock } from "./helpers.js";

/**
 * A store whose state reads take a while, as over a network: two processes
 * reading at about the same time both get the old state before either writes.
 */
function slowReads(store: Store, options: { withoutCas?: boolean } = {}): Store {
  return new Proxy(store, {
    get(target, prop, receiver) {
      if (prop === "compareAndSetState" && options.withoutCas) return undefined;
      const value = Reflect.get(target, prop, receiver);
      if (typeof value !== "function") return value;
      if (prop === "getState") {
        return async (...args: unknown[]) => {
          const state = await value.apply(target, args);
          await new Promise((r) => setTimeout(r, 25));
          return state;
        };
      }
      return (...args: unknown[]) => value.apply(target, args);
    },
  });
}

/** Two clients, as two processes sharing one store, each failing the job once at the same time. */
async function race(storeA: Store, storeB: Store) {
  const c = clock();
  const a = capture();
  const b = capture();
  const one = cronwatch({ store: storeA, now: c.now, alerts: [a], cronSecret: null });
  const two = cronwatch({ store: storeB, now: c.now, alerts: [b], cronSecret: null });
  const options = { failuresBeforeAlert: 2 };
  await one.run("shared", options, async () => {});
  await Promise.allSettled([
    one.run("shared", options, async () => { throw new Error("one"); }),
    two.run("shared", options, async () => { throw new Error("two"); }),
  ]);
  const state = (await storeA.getState("shared"))!;
  return { state, types: [...a.types(), ...b.types()], one, two };
}

test("two processes failing a job at once: both failures count and the alert goes out once", async () => {
  const store = memory();
  const { state, types } = await race(slowReads(store), slowReads(store));
  assert.equal(state.consecutiveFailures, 2, "neither failure was lost");
  assert.deepEqual(Object.keys(state.open), ["failed"], "the condition opened");
  assert.deepEqual(types, ["failed"], "one alert, from whichever process counted the second failure");
  assert.ok((state.version ?? 0) >= 3, `every write bumped the version (${state.version})`);
});

test("the same race through two SQLite connections to one file", async () => {
  const dir = mkdtempSync(path.join(tmpdir(), "cronwatch-race-"));
  const file = path.join(dir, "cw.db");
  const first = sqlite({ path: file });
  const second = sqlite({ path: file });
  try {
    const { state, types, one, two } = await race(slowReads(first), slowReads(second));
    assert.equal(state.consecutiveFailures, 2);
    assert.deepEqual(types, ["failed"]);
    await one.close();
    await two.close();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a custom store without compareAndSetState still works, but cannot keep two processes apart", async () => {
  const store = memory();
  const { state, types } = await race(slowReads(store, { withoutCas: true }), slowReads(store, { withoutCas: true }));
  // The documented caveat: the later write wins, so one failure is lost.
  assert.equal(state.consecutiveFailures, 1);
  assert.deepEqual(types, []);
});

test("a silence made by one process survives another process's run", async () => {
  const store = memory();
  const c = clock();
  const runner = cronwatch({ store: slowReads(store), now: c.now, alerts: [capture()], cronSecret: null });
  const admin = cronwatch({ store: slowReads(store), now: c.now, alerts: [capture()], cronSecret: null });
  await runner.run("s", async () => {});
  await Promise.all([
    assert.rejects(runner.run("s", async () => { throw new Error("x"); })),
    admin.silence("s", "1h"),
  ]);
  const state = (await store.getState("s"))!;
  assert.notEqual(state.silencedUntil, null, "the silence was not overwritten");
  assert.equal(state.consecutiveFailures, 1, "nor was the failure");
});

test("an update that keeps losing gives up and reports, and the run still finishes", async () => {
  const errors: string[] = [];
  const store = memory();
  // Always refuses: as if another process wrote between every read and write.
  const contested: Store = { ...store, compareAndSetState: async () => false };
  const cw = cronwatch({ store: contested, alerts: [capture()], cronSecret: null, onError: (_e, where) => errors.push(where) });
  await assert.rejects(cw.run("busy", async () => { throw new Error("x"); }), /x/);
  assert.deepEqual(errors, ["evaluating busy"]);
  assert.equal((await cw.runs("busy"))[0]!.status, "failed");
});
