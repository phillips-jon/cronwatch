import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { changedUrls, fileFor, findKey, submit } from "./indexnow.mjs";

const KEY = "0123456789abcdef0123456789abcdef";

function dist(pages, { key = true } = {}) {
  const dir = mkdtempSync(path.join(tmpdir(), "indexnow-"));
  if (key) writeFileSync(path.join(dir, `${KEY}.txt`), KEY);
  for (const [file, html] of Object.entries(pages)) {
    mkdirSync(path.dirname(path.join(dir, file)), { recursive: true });
    writeFileSync(path.join(dir, file), html);
  }
  const urls = Object.keys(pages).map((f) => `https://cronwatch.dev/${f.replace(/index\.html$/, "")}`);
  writeFileSync(path.join(dir, "sitemap.xml"), `<urlset>${urls.map((u) => `<url><loc>${u}</loc></url>`).join("")}</urlset>`);
  return dir;
}

test("finds the key file that holds its own name, and no other", () => {
  assert.equal(findKey(dist({})), KEY);
  const dir = dist({}, { key: false });
  writeFileSync(path.join(dir, `${KEY}.txt`), "something else");
  assert.equal(findKey(dir), null);
});

test("maps a URL to the file nginx serves", () => {
  const dir = dist({ "index.html": "a", "docs/index.html": "b" });
  assert.equal(fileFor(dir, "https://cronwatch.dev/"), path.join(dir, "index.html"));
  assert.equal(fileFor(dir, "https://cronwatch.dev/docs/"), path.join(dir, "docs/index.html"));
  assert.equal(fileFor(dir, "https://cronwatch.dev/docs"), path.join(dir, "docs/index.html"));
  assert.equal(fileFor(dir, "https://cronwatch.dev/nope/"), null);
});

test("submits only the pages that changed, ignoring asset hashes", () => {
  const css = (h) => `<link href="/assets/style.${h}.css"><script src="/assets/site.${h}.js"></script>`;
  const old = dist({ "index.html": `${css("aaaaaaaaaa")}home`, "docs/index.html": "docs", "docs/go/index.html": "go" });
  const now = dist({ "index.html": `${css("bbbbbbbbbb")}home`, "docs/index.html": "docs, edited", "docs/go/index.html": "go", "docs/new/index.html": "new" });
  assert.deepEqual(changedUrls(now, old), ["https://cronwatch.dev/docs/", "https://cronwatch.dev/docs/new/"]);
});

test("submits every page without an old release, or one with no key yet", () => {
  const now = dist({ "index.html": "home", "docs/index.html": "docs" });
  assert.equal(changedUrls(now).length, 2);
  assert.equal(changedUrls(now, dist({ "index.html": "home", "docs/index.html": "docs" }, { key: false })).length, 2);
});

test("posts the host, key, key location, and URLs", async () => {
  let sent;
  const status = await submit(["https://cronwatch.dev/", "https://cronwatch.dev/docs/"], KEY, {
    fetch: async (url, init) => { sent = { url, body: JSON.parse(init.body) }; return { status: 202 }; },
  });
  assert.equal(status, 202);
  assert.equal(sent.url, "https://api.indexnow.org/indexnow");
  assert.deepEqual(sent.body, {
    host: "cronwatch.dev",
    key: KEY,
    keyLocation: `https://cronwatch.dev/${KEY}.txt`,
    urlList: ["https://cronwatch.dev/", "https://cronwatch.dev/docs/"],
  });
});
