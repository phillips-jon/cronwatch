import assert from "node:assert/strict";
import { test } from "node:test";
import { environment, isDevelopment, isProduction } from "../src/env.js";

const NAMES = ["CRONWATCH_ENV", "APP_ENV", "NODE_ENV"] as const;

function withEnv(values: Partial<Record<(typeof NAMES)[number], string>>, fn: () => void): void {
  const saved = Object.fromEntries(NAMES.map((name) => [name, process.env[name]]));
  try {
    for (const name of NAMES) {
      if (values[name] === undefined) delete process.env[name];
      else process.env[name] = values[name];
    }
    fn();
  } finally {
    for (const name of NAMES) {
      if (saved[name] === undefined) delete process.env[name];
      else process.env[name] = saved[name];
    }
  }
}

test("the environment is the first of CRONWATCH_ENV, APP_ENV, and NODE_ENV that is set, as in every port", () => {
  const cases: [Partial<Record<(typeof NAMES)[number], string>>, string][] = [
    [{}, ""],
    [{ NODE_ENV: "development" }, "development"],
    [{ NODE_ENV: "test" }, "development"],
    [{ NODE_ENV: "production" }, "production"],
    [{ APP_ENV: "local", NODE_ENV: "production" }, "development"],
    [{ CRONWATCH_ENV: "production", APP_ENV: "dev", NODE_ENV: "development" }, "production"],
    [{ CRONWATCH_ENV: "staging", NODE_ENV: "development" }, "staging"],
    // Trimmed and lowercased; "prod" is production; dev, local, test, and testing are development.
    [{ CRONWATCH_ENV: "  PROD " }, "production"],
    [{ APP_ENV: "Testing" }, "development"],
    [{ APP_ENV: "DEV" }, "development"],
    // Empty or only spaces counts as unset, so the next one is read.
    [{ CRONWATCH_ENV: "", APP_ENV: "   ", NODE_ENV: "production" }, "production"],
    [{ CRONWATCH_ENV: " \t" }, ""],
  ];
  for (const [values, expected] of cases) {
    withEnv(values, () => {
      assert.equal(environment(), expected, JSON.stringify(values));
      assert.equal(isDevelopment(), expected === "development", JSON.stringify(values));
      assert.equal(isProduction(), expected === "production", JSON.stringify(values));
    });
  }
});
