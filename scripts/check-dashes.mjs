/**
 * Fails if an em dash (U+2014) or en dash (U+2013) appears anywhere in the
 * repository. Runs before every build and test, so one can never quietly appear.
 *
 * Scans every file git tracks or would track (untracked files not ignored by
 * .gitignore), whatever its extension, skipping only binaries. Outside a git
 * checkout it walks the tree instead.
 *
 *   node scripts/check-dashes.mjs                 the files
 *   node scripts/check-dashes.mjs --commits A..B  the messages of those commits
 *                                                 (everything after --commits goes to git log)
 *
 * Ordinary hyphens are fine.
 */
import { execFileSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";

const ROOT = process.cwd();
// .agents and .claude hold third-party skills installed by tooling, not our prose.
const SKIP_DIRS = new Set(["node_modules", ".git", "dist", "data", ".next", "out", ".agents", ".claude"]);
const BINARY = new Set([
  ".png", ".jpg", ".jpeg", ".gif", ".webp", ".avif", ".ico", ".woff", ".woff2", ".ttf", ".otf",
  ".pdf", ".zip", ".gz", ".tgz", ".db", ".sqlite",
]);
// Written as escapes so this file does not trip its own check.
const BAD = /[\u2013\u2014]/;

const hits = [];

function scan(label, text) {
  text.split("\n").forEach((line, i) => {
    if (BAD.test(line)) hits.push(`${label}:${i + 1}  ${line.trim().slice(0, 90)}`);
  });
}

function git(args) {
  return execFileSync("git", args, { cwd: ROOT, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
}

function listFiles() {
  try {
    const out = git(["ls-files", "-z", "--cached", "--others", "--exclude-standard"]);
    return out.split("\0").filter((f) => f && !f.split("/").some((part) => SKIP_DIRS.has(part)));
  } catch {
    const files = [];
    const walk = (dir) => {
      for (const entry of readdirSync(dir)) {
        if (SKIP_DIRS.has(entry)) continue;
        if (entry.startsWith(".env") && entry !== ".env.example") continue;
        const full = path.join(dir, entry);
        if (statSync(full).isDirectory()) walk(full);
        else files.push(path.relative(ROOT, full));
      }
    };
    walk(ROOT);
    return files;
  }
}

const commitsAt = process.argv.indexOf("--commits");
if (commitsAt >= 0) {
  const revisions = process.argv.slice(commitsAt + 1);
  if (revisions.length === 0) {
    console.error("check-dashes: --commits needs a revision range, e.g. origin/main..HEAD");
    process.exit(2);
  }
  const log = git(["log", "--format=%H%x00%B%x01", ...revisions]);
  for (const entry of log.split("\x01")) {
    const [sha, message] = entry.replace(/^\n/, "").split("\0");
    if (sha && message !== undefined) scan(`commit ${sha.slice(0, 12)}`, message);
  }
} else {
  for (const file of listFiles()) {
    if (BINARY.has(path.extname(file).toLowerCase())) continue;
    const full = path.join(ROOT, file);
    // A tracked file deleted in the working tree, or a submodule.
    if (!existsSync(full) || !statSync(full).isFile()) continue;
    const buffer = readFileSync(full);
    if (buffer.subarray(0, 8000).includes(0)) continue;
    scan(file, buffer.toString("utf8"));
  }
}

if (hits.length > 0) {
  console.error(`\nFound ${hits.length} em/en dash(es). Use a period, colon, comma or parentheses.\n`);
  for (const h of hits) console.error("  " + h);
  console.error("");
  process.exit(1);
}

console.log(commitsAt >= 0 ? "check-dashes: commit messages clean" : "check-dashes: clean");
