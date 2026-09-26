import assert from "node:assert/strict";
import { test } from "node:test";
import { formatDuration, formatRelative, parseDuration } from "../src/duration.js";

test("parseDuration reads units and compounds", () => {
  assert.equal(parseDuration("15m"), 900_000);
  assert.equal(parseDuration("1h30m"), 5_400_000);
  assert.equal(parseDuration("90s"), 90_000);
  assert.equal(parseDuration("2d"), 172_800_000);
  assert.equal(parseDuration("1w"), 604_800_000);
  assert.equal(parseDuration("250ms"), 250);
  assert.equal(parseDuration(" 1h 5m "), 3_900_000);
  assert.equal(parseDuration(1234), 1234);
  assert.equal(parseDuration("1.5h"), 5_400_000);
});

test("parseDuration rejects nonsense", () => {
  for (const bad of ["", "abc", "5", "5 minutes", "-1m", "1m2"]) {
    assert.throws(() => parseDuration(bad), new RegExp("duration"), bad);
  }
  assert.throws(() => parseDuration(-5));
});

test("formatDuration and formatRelative", () => {
  assert.equal(formatDuration(500), "500ms");
  assert.equal(formatDuration(1_000), "1s");
  assert.equal(formatDuration(90_000), "1m 30s");
  assert.equal(formatDuration(3_600_000 * 26 + 60_000 * 5), "1d 2h");
  assert.equal(formatRelative(1_000_000, 1_000_000 + 120_000), "2m ago");
  assert.equal(formatRelative(1_000_000 + 120_000, 1_000_000), "in 2m");
  assert.equal(formatRelative(1_000_000, 1_000_000 + 2_000), "now");
});
