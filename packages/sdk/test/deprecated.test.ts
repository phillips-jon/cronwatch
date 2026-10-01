// Names kept for 1.x under a new spelling, each marked @deprecated: the old
// name must keep doing exactly what the new one does until 2.0.
import assert from "node:assert/strict";
import { test } from "node:test";
import * as sdk from "../src/index.js";
import { Cronwatch, CronWatch, cronwatch } from "../src/index.js";
import type { CronwatchOptions, CronWatchOptions } from "../src/index.js";

test("CronWatch is Cronwatch, as a value and as a type", () => {
  assert.equal(CronWatch, Cronwatch);
  const old: CronWatch = new CronWatch({ alerts: [] });
  assert.ok(old instanceof Cronwatch);
  assert.ok(cronwatch({ alerts: [] }) instanceof CronWatch);
  const options: CronWatchOptions = { retention: "1d" } satisfies CronwatchOptions;
  assert.equal(new Cronwatch(options).retentionMs, 86_400_000);
  assert.ok("Cronwatch" in sdk && "CronWatch" in sdk);
});
