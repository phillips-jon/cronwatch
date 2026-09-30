// The changelog sections scripts/release.mjs writes.
//
//   node --test scripts/changelogs.test.mjs
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { addMarkdownChangelog, addReadmeChangelog, today } from "./changelogs.mjs";

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

test("today is the local date", () => {
  assert.equal(today(new Date(2026, 0, 5, 23, 59)), "2026-01-05");
});

for (const file of ["packages/php/craft/CHANGELOG.md", "packages/php/drupal/CHANGELOG.md"]) {
  test(`${file} has dated releases, newest first, under at most one Unreleased`, () => {
    const text = readFileSync(new URL(`../${file}`, import.meta.url), "utf8");
    const headings = [...text.matchAll(/^## (.*)$/gm)].map((m) => m[1]);
    assert.ok(headings.filter((h) => h === "Unreleased").length <= 1);
    const released = headings.filter((h) => h !== "Unreleased");
    assert.ok(released.length > 0);
    for (const h of released) assert.match(h, /^\d+\.\d+\.\d+ - \d{4}-\d{2}-\d{2}$/);
    const versions = released.map((h) => h.split(" ")[0].split(".").map(Number));
    for (let i = 1; i < versions.length; i++) {
      const [a, b] = [versions[i - 1], versions[i]];
      assert.ok(a[0] > b[0] || (a[0] === b[0] && (a[1] > b[1] || (a[1] === b[1] && a[2] > b[2]))), `${released[i - 1]} before ${released[i]}`);
    }
  });
}
