// The changelog sections scripts/release.mjs writes.
//
//   node --test scripts/changelogs.test.mjs
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { addMarkdownChangelog, addReadmeChangelog, addRootChangelog, today } from "./changelogs.mjs";

const MARKDOWN = "# Release Notes for CronWatch\n\n## Unreleased\n\n### Fixed\n- A thing.\n\n## 1.2.3 - 2026-09-30\n\n### Changed\n- Updated to the library's 1.2.3.\n";

test("a CHANGELOG.md's Unreleased section becomes the release's, dated", () => {
  const { text, change, written } = addMarkdownChangelog(MARKDOWN, "1.3.0", "2026-10-01");
  assert.equal(text, MARKDOWN.replace("## Unreleased", "## 1.3.0 - 2026-10-01"));
  assert.equal(change, "## Unreleased -> ## 1.3.0 - 2026-10-01");
  assert.equal(written, true);
});

test("without an Unreleased section, a placeholder goes above the newest release", () => {
  const released = MARKDOWN.replace("## Unreleased\n\n### Fixed\n- A thing.\n\n", "");
  const { text, change, written } = addMarkdownChangelog(released, "1.3.0", "2026-10-01");
  assert.equal(text, "# Release Notes for CronWatch\n\n## 1.3.0 - 2026-10-01\n\n### Changed\n- Updated to the library's 1.3.0.\n\n## 1.2.3 - 2026-09-30\n\n### Changed\n- Updated to the library's 1.2.3.\n");
  assert.match(change, /placeholder/);
  assert.equal(written, false);
});

test("a release already in a CHANGELOG.md is left as it is", () => {
  const { text, written } = addMarkdownChangelog(MARKDOWN, "1.2.3", "2026-10-01");
  assert.equal(text, MARKDOWN);
  assert.equal(written, true);
});

test("a CHANGELOG.md with no released section is refused", () => {
  assert.throws(() => addMarkdownChangelog("# Release Notes for CronWatch\n", "1.3.0", "2026-10-01", "x/CHANGELOG.md"), /x\/CHANGELOG\.md: no "## X\.Y\.Z/);
});

test("the WordPress readme's = Unreleased = becomes = X.Y.Z =, and a placeholder without it", () => {
  const readme = "== Changelog ==\n\n= Unreleased =\n\n* A thing.\n\n= 1.2.3 =\n\n* Carries version 1.2.3 of the CronWatch library.\n";
  assert.equal(addReadmeChangelog(readme, "1.3.0").text, readme.replace("= Unreleased =", "= 1.3.0 ="));
  const released = readme.replace("= Unreleased =\n\n* A thing.\n\n", "");
  const { text, written } = addReadmeChangelog(released, "1.3.0");
  assert.equal(text, released.replace("= 1.2.3 =", "= 1.3.0 =\n\n* Carries version 1.3.0 of the CronWatch library.\n\n= 1.2.3 ="));
  assert.equal(written, false);
});

test("the root CHANGELOG.md's Unreleased section becomes the release's, and a release without one is refused", () => {
  const root = "# Changelog\n\n## Unreleased\n\n### Fixed\n\n- A thing.\n\n## 0.10.0 and earlier\n\nSee the GitHub releases.\n";
  const { text, change, written } = addRootChangelog(root, "1.0.0", "2026-10-01");
  assert.equal(text, root.replace("## Unreleased", "## 1.0.0 - 2026-10-01"));
  assert.equal(change, "## Unreleased -> ## 1.0.0 - 2026-10-01");
  assert.equal(written, true);
  assert.equal(addRootChangelog(text, "1.0.0", "2026-10-02").text, text);
  assert.throws(() => addRootChangelog(text, "1.0.1", "2026-10-02"), /CHANGELOG\.md: no "## Unreleased" section/);
});

test("today is the local date", () => {
  assert.equal(today(new Date(2026, 0, 5, 23, 59)), "2026-01-05");
});

/**
 * Semantic Versioning's precedence (semver.org, item 11): a release comes
 * after its prereleases (1.3.0-beta.1 < 1.3.0), and prerelease identifiers
 * compare numerically when both are numbers, by ASCII otherwise, a number
 * before a word, a shorter list first.
 */
function compareVersions(a, b) {
  const split = (v) => {
    const [core, pre] = v.split(/-(.*)/s);
    return { core: core.split(".").map(Number), pre: pre === undefined ? [] : pre.split(".") };
  };
  const [x, y] = [split(a), split(b)];
  for (let i = 0; i < 3; i++) if (x.core[i] !== y.core[i]) return x.core[i] - y.core[i];
  if (x.pre.length === 0 || y.pre.length === 0) return y.pre.length - x.pre.length;
  for (let i = 0; i < Math.min(x.pre.length, y.pre.length); i++) {
    const [p, q] = [x.pre[i], y.pre[i]];
    if (p === q) continue;
    const [pn, qn] = [/^\d+$/.test(p), /^\d+$/.test(q)];
    if (pn && qn) return Number(p) - Number(q);
    if (pn !== qn) return pn ? -1 : 1;
    return p < q ? -1 : 1;
  }
  return x.pre.length - y.pre.length;
}

/** Dated releases (a prerelease among them), newest first, under at most one Unreleased. */
function checkChangelog(text) {
  const headings = [...text.matchAll(/^## (.*)$/gm)].map((m) => m[1]);
  assert.ok(headings.filter((h) => h === "Unreleased").length <= 1);
  const released = headings.filter((h) => h !== "Unreleased");
  assert.ok(released.length > 0);
  for (const h of released) assert.match(h, /^\d+\.\d+\.\d+(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)? - \d{4}-\d{2}-\d{2}$/);
  const versions = released.map((h) => h.split(" ")[0]);
  for (let i = 1; i < versions.length; i++) assert.ok(compareVersions(versions[i - 1], versions[i]) > 0, `${released[i - 1]} before ${released[i]}`);
}

test("compareVersions orders by Semantic Versioning's precedence", () => {
  const sorted = ["0.9.0", "0.10.0-alpha", "0.10.0-alpha.1", "0.10.0-alpha.beta", "0.10.0-beta", "0.10.0-beta.2", "0.10.0-beta.11", "0.10.0-rc.1", "0.10.0", "0.10.1", "1.0.0"];
  for (let i = 1; i < sorted.length; i++) {
    assert.ok(compareVersions(sorted[i - 1], sorted[i]) < 0, `${sorted[i - 1]} < ${sorted[i]}`);
    assert.ok(compareVersions(sorted[i], sorted[i - 1]) > 0, `${sorted[i]} > ${sorted[i - 1]}`);
  }
  assert.equal(compareVersions("1.2.3-beta.1", "1.2.3-beta.1"), 0);
});

test("a prerelease is cut, then its release, and the changelog still checks", () => {
  const beta =addMarkdownChangelog(MARKDOWN, "1.3.0-beta.1", "2026-10-01");
  assert.match(beta.text, /^## 1\.3\.0-beta\.1 - 2026-10-01$/m);
  checkChangelog(beta.text);
  const beta2 = addMarkdownChangelog(beta.text, "1.3.0-beta.2", "2026-10-02");
  checkChangelog(beta2.text);
  const final = addMarkdownChangelog(beta2.text, "1.3.0", "2026-10-03");
  assert.match(final.text, /^## 1\.3\.0 - 2026-10-03\n[^]*^## 1\.3\.0-beta\.2 - /m);
  assert.equal(final.written, false, "1.3.0-beta.2's section does not count as 1.3.0's");
  checkChangelog(final.text);
  assert.throws(() => checkChangelog(addMarkdownChangelog(final.text, "1.3.0-rc.1", "2026-10-04").text), /1\.3\.0-rc\.1 - 2026-10-04 before 1\.3\.0 -/);
  const readme = addReadmeChangelog("== Changelog ==\n\n= 1.2.3 =\n\n* Carries version 1.2.3 of the CronWatch library.\n", "1.3.0-beta.1");
  assert.match(readme.text, /^= 1\.3\.0-beta\.1 =$/m);
  assert.equal(addReadmeChangelog(readme.text, "1.3.0").written, false);
});

test("CHANGELOG.md has dated releases, newest first, under at most one Unreleased, then the earlier releases' line", () => {
  const text = readFileSync(new URL("../CHANGELOG.md", import.meta.url), "utf8");
  const [current, earlier] = text.split(/^## 0\.10\.0 and earlier$/m);
  assert.ok(earlier !== undefined, 'the "## 0.10.0 and earlier" line is there, last');
  assert.doesNotMatch(earlier, /^## /m);
  const headings = [...current.matchAll(/^## (.*)$/gm)].map((m) => m[1]);
  assert.ok(headings.filter((h) => h === "Unreleased").length <= 1);
  if (headings.some((h) => h !== "Unreleased")) checkChangelog(current);
});

for (const file of ["packages/php/craft/CHANGELOG.md", "packages/php/drupal/CHANGELOG.md"]) {
  test(`${file} has dated releases, newest first, under at most one Unreleased`, () => {
    checkChangelog(readFileSync(new URL(`../${file}`, import.meta.url), "utf8"));
  });
}
