/**
 * Fails if an em dash (U+2014) or en dash (U+2013) appears anywhere in the
 * source. Runs before every build and test, so one can never quietly appear.
 *
 * Ordinary hyphens are fine.
 */
import { readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";

const ROOT = process.cwd();
// .agents and .claude hold third-party skills installed by tooling, not our prose.
const SKIP = new Set(["node_modules", ".git", "dist", "data", ".next", "out", ".agents", ".claude"]);
const EXT = new Set([
  ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".css", ".md", ".json",
  ".html", ".yml", ".yaml", ".conf", ".service", ".example", ".txt",
]);
// Written as escapes so this file does not trip its own check.
const BAD = /[\u2013\u2014]/;

const hits = [];

function walk(dir) {
  for (const entry of readdirSync(dir)) {
    if (SKIP.has(entry)) continue;
    if (entry.startsWith(".env") && entry !== ".env.example") continue;
    const full = path.join(dir, entry);
    if (statSync(full).isDirectory()) {
      walk(full);
      continue;
    }
    if (!EXT.has(path.extname(entry)) && !["deploy", "rollback", "release-deploy"].includes(entry)) continue;
    const lines = readFileSync(full, "utf8").split("\n");
    lines.forEach((line, i) => {
      if (BAD.test(line)) {
        hits.push(`${path.relative(ROOT, full)}:${i + 1}  ${line.trim().slice(0, 90)}`);
      }
    });
  }
}

walk(ROOT);

if (hits.length > 0) {
  console.error(`\nFound ${hits.length} em/en dash(es). Use a period, colon, comma or parentheses.\n`);
  for (const h of hits) console.error("  " + h);
  console.error("");
  process.exit(1);
}

console.log("check-dashes: clean");
