// The version edits scripts/release.mjs plans: cronwatch-apalis's own 0.x
// line, and the install lines that name a minor.
//
//   node --test scripts/release.test.mjs
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { apalisVersion, minorOf, planEdits, VERSIONED } from "./release.mjs";

const ROOT = path.resolve(import.meta.dirname, "..");
const readRepo = (file) => readFileSync(path.join(ROOT, file), "utf8");
const current = JSON.parse(readRepo("packages/sdk/package.json")).version;
// The next major release, and the minor its install lines name.
const MAJOR = `${Number(current.split(".")[0]) + 1}.0.0`;
const M = `${Number(current.split(".")[0]) + 1}.0`;

test("cronwatch-apalis shares the release's version below 1.0", () => {
  assert.equal(apalisVersion("0.10.0", "0.10.0", "0.11.0"), "0.11.0");
  assert.equal(apalisVersion("0.10.0", "0.10.0", "0.10.1"), "0.10.1");
  assert.equal(apalisVersion("0.10.0", "0.10.0", "0.11.0-beta.1"), "0.11.0-beta.1");
});

test("from 1.0, cronwatch-apalis keeps a 0.x line of its own", () => {
  assert.equal(apalisVersion("0.10.0", "0.10.0", "1.0.0"), "0.11.0");
  assert.equal(apalisVersion("0.11.0", "1.0.0", "1.0.1"), "0.11.1");
  assert.equal(apalisVersion("0.11.1", "1.0.1", "1.1.0"), "0.12.0");
  assert.equal(apalisVersion("0.12.0", "1.1.0", "2.0.0"), "0.13.0");
  // A prerelease of 1.0 and then 1.0 itself.
  assert.equal(apalisVersion("0.10.0", "0.10.0", "1.0.0-beta.1"), "0.11.0-beta.1");
  assert.equal(apalisVersion("0.11.0-beta.1", "1.0.0-beta.1", "1.0.0-beta.2"), "0.11.0-beta.2");
  assert.equal(apalisVersion("0.11.0-beta.2", "1.0.0-beta.2", "1.0.0"), "0.11.0");
  assert.throws(() => apalisVersion("1.0.0", "1.0.0", "1.1.0"), /version\.workspace/);
});

test("an install line names the minor", () => {
  assert.equal(minorOf("0.10.0"), "0.10");
  assert.equal(minorOf("1.2.3-beta.1"), "1.2");
});

test("the repository's files are in step with the release's version", () => {
  assert.doesNotThrow(() => planEdits(VERSIONED, readRepo, current, "99.0.0"));
});

test("a major release moves the install lines and keeps cronwatch-apalis below 1.0", () => {
  const edits = planEdits(VERSIONED, readRepo, current, MAJOR);
  const after = (file) => edits.get(file).after;
  const m = M.replace(".", "\\.");
  assert.match(after("packages/rust/Cargo.toml"), new RegExp(`^version = "${MAJOR}"$`, "m"));
  const apalis = /^version = "0\.(\d+)\.0"$/m.exec(after("packages/rust/cronwatch-apalis/Cargo.toml"))?.[1];
  assert.ok(apalis, "cronwatch-apalis stays at 0.x");
  for (const file of ["packages/rust/README.md", "site/docs/rust.md"]) {
    assert.doesNotMatch(after(file), /^cronwatch(-sqlx)? = (\{ version = )?"0\./m, file);
    assert.match(after(file), new RegExp(`^cronwatch(-sqlx)? = (\\{ version = )?"${m}"`, "m"), file);
  }
  for (const file of ["packages/rust/cronwatch-apalis/README.md", "site/docs/rust-schedulers.md"]) {
    assert.match(after(file), new RegExp(`^cronwatch-apalis = "0\\.${apalis}"$`, "m"), file);
    assert.match(after(file), new RegExp(`^cronwatch = "${m}"$`, "m"), file);
  }
  for (const file of ["README.md", "packages/elixir/README.md", "site/docs/elixir.md", "site/src/prompt.txt", "skills/cronwatch/SKILL.md"]) {
    assert.ok(after(file).includes(`{:cronwatch, "~> ${M}"}`), file);
    assert.doesNotMatch(after(file), /\{:cronwatch, "~> 0\./, file);
  }
  assert.ok(after("site/src/landing.html").includes(`{:cronwatch, "~&gt; ${M}"}`));
  assert.ok(after("site/build.mjs").includes(`{:cronwatch, \\"~> ${M}\\"}`));
});

test("a prerelease leaves the install lines alone", () => {
  const edits = planEdits(VERSIONED, readRepo, current, `${MAJOR}-beta.1`);
  assert.equal(edits.get("site/docs/elixir.md").after, readRepo("site/docs/elixir.md"));
  assert.equal(edits.get("packages/rust/README.md").after, readRepo("packages/rust/README.md"));
  assert.match(edits.get("packages/rust/cronwatch-apalis/Cargo.toml").after, /^version = "0\.\d+\.0-beta\.1"$/m);
});

test("an install line out of step is refused", () => {
  const read = (file) => (file === "site/docs/elixir.md" ? readRepo(file).replace(/~> \d+\.\d+/, "~> 0.1") : readRepo(file));
  assert.throws(() => planEdits(VERSIONED, read, current, "99.0.0"), /site\/docs\/elixir\.md says 0\.1/);
});
