/**
 * Cuts a release: bumps every version the release carries, regenerates the
 * lockfile and fixtures, runs every check, then commits "Release <version>"
 * and tags v<version>. It never pushes or publishes; it prints those commands.
 *
 *   node scripts/release.mjs <version> [options]
 *   npm run release -- <version> [options]
 *
 *   --dry-run          print every change and command, write nothing
 *   --branch <name>    release from this branch instead of main (for testing)
 *   --skip-ruby        skip the gem's tests
 *   --skip-python      skip the Python package's tests
 *   --deprecate <old>  also print `npm deprecate` for these versions (a version
 *                      or range, e.g. "<0.3.0"); may be given more than once
 *
 * A new language package under packages/ needs a row in VERSIONED (the file
 * holding its version), and a row in PUBLISH (how it ships). The script
 * refuses to run while a package directory is missing either row.
 */
import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";

/** Every place the release version lives. Each pattern captures (before)(version)(after). */
const VERSIONED = [
  { file: "packages/sdk/package.json", pattern: /^( {2}"version": ")([^"]+)(")/m },
  { file: "packages/mcp/package.json", pattern: /^( {2}"version": ")([^"]+)(")/m },
  { file: "packages/mcp/package.json", pattern: /^( {4}"@cronwatch\/sdk": ")([^"]+)(")/m },
  { file: "packages/ruby/lib/cronwatch/version.rb", pattern: /^(\s*VERSION = ")([^"]+)(")/m },
  { file: "packages/python/pyproject.toml", pattern: /^(version = ")([^"]+)(")/m },
  { file: "packages/python/src/cronwatch/__init__.py", pattern: /^(__version__ = ")([^"]+)(")/m },
  { file: "skills/cronwatch/SKILL.md", pattern: /^(version: )(\S+)()$/m },
];

/** How each package ships, printed after the release commit, in order. Given the semver and the RubyGems version. */
const PUBLISH = [
  { dir: "packages/sdk", commands: () => ["npm publish --workspace packages/sdk --access public"] },
  { dir: "packages/mcp", commands: () => ["npm publish --workspace packages/mcp --access public"] },
  { dir: "packages/ruby", commands: (v, gem) => [`(cd packages/ruby && gem build cronwatch.gemspec && gem push cronwatch-${gem}.gem)`] },
  { dir: "packages/python", commands: () => ["(cd packages/python && rm -rf dist && uv build && uv publish)"] },
];

/** Files the built gem must carry, and prefixes it must not. */
const GEM_REQUIRED = ["lib/cronwatch.rb", "lib/cronwatch/client.rb", "lib/cronwatch/pg_cron.rb", "lib/cronwatch/run_handle.rb"];
const GEM_FORBIDDEN = ["test/", "conformance/"];

/** npm packages `--deprecate` covers. RubyGems has no deprecation; yank only a broken gem. */
const NPM_PACKAGES = ["@cronwatch/sdk", "@cronwatch/mcp"];

/** Files the steps regenerate, reported by --dry-run. */
const REGENERATED = ["package-lock.json", "conformance/*.json (sdkVersion)", "packages/ruby/test/web/golden.json"];

const ROOT = process.cwd();
const SEMVER = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?(?:\+([0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?$/;

/** "a", "a and b", "a, b and c". */
function listed(items) {
  return items.length < 2 ? items.join("") : `${items.slice(0, -1).join(", ")} and ${items.at(-1)}`;
}

function fail(message) {
  console.error(`release: ${message}`);
  process.exit(1);
}

function parseArgs(argv) {
  const options = { version: null, dryRun: false, branch: "main", skipRuby: false, skipPython: false, deprecate: [] };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const value = () => {
      const next = argv[++i];
      if (next === undefined || next.startsWith("--")) fail(`${arg} needs a value`);
      return next;
    };
    if (arg === "--dry-run") options.dryRun = true;
    else if (arg === "--skip-ruby") options.skipRuby = true;
    else if (arg === "--skip-python") options.skipPython = true;
    else if (arg === "--branch") options.branch = value();
    else if (arg === "--deprecate") options.deprecate.push(value());
    else if (arg === "--help" || arg === "-h") {
      console.log("usage: node scripts/release.mjs <version> [--dry-run] [--branch <name>] [--skip-ruby] [--skip-python] [--deprecate <old>]");
      process.exit(0);
    } else if (arg.startsWith("--")) fail(`unknown option ${arg}`);
    else if (options.version === null) options.version = arg.replace(/^v/, "");
    else fail(`unexpected argument ${arg}`);
  }
  if (options.version === null) fail("usage: node scripts/release.mjs <version> [--dry-run] [--branch <name>] [--skip-ruby] [--skip-python] [--deprecate <old>]");
  return options;
}

/** Semver precedence: negative, zero or positive, as a is lower, equal or higher. Build metadata is ignored. */
function compareVersions(a, b) {
  const [, ...pa] = SEMVER.exec(a);
  const [, ...pb] = SEMVER.exec(b);
  for (let i = 0; i < 3; i++) {
    const d = Number(pa[i]) - Number(pb[i]);
    if (d !== 0) return d;
  }
  const [ra, rb] = [pa[3], pb[3]];
  if (ra === undefined || rb === undefined) return ra === rb ? 0 : ra === undefined ? 1 : -1;
  const ia = ra.split(".");
  const ib = rb.split(".");
  for (let i = 0; i < Math.max(ia.length, ib.length); i++) {
    if (ia[i] === undefined) return -1;
    if (ib[i] === undefined) return 1;
    const na = /^\d+$/.test(ia[i]);
    const nb = /^\d+$/.test(ib[i]);
    if (na && nb) {
      const d = Number(ia[i]) - Number(ib[i]);
      if (d !== 0) return d;
    } else if (na !== nb) return na ? -1 : 1;
    else if (ia[i] !== ib[i]) return ia[i] < ib[i] ? -1 : 1;
  }
  return 0;
}

function git(...args) {
  return execFileSync("git", args, { cwd: ROOT, encoding: "utf8" }).trimEnd();
}

function read(file) {
  return readFileSync(path.join(ROOT, file), "utf8");
}

/**
 * Every packages/* directory must have a VERSIONED row, so a new package is
 * not released at a stale version, and a PUBLISH row, so it is not left unshipped.
 */
function checkTable() {
  const dirs = readdirSync(path.join(ROOT, "packages")).filter((d) => statSync(path.join(ROOT, "packages", d)).isDirectory());
  const unversioned = dirs.filter((d) => !VERSIONED.some((row) => row.file.startsWith(`packages/${d}/`)));
  if (unversioned.length > 0) fail(`no VERSIONED row for ${unversioned.map((d) => `packages/${d}`).join(", ")}; add the file that holds its version to the table in scripts/release.mjs`);
  const unpublished = dirs.filter((d) => !PUBLISH.some((row) => row.dir === `packages/${d}`));
  if (unpublished.length > 0) fail(`no PUBLISH row for ${unpublished.map((d) => `packages/${d}`).join(", ")}; add how it ships to the table in scripts/release.mjs`);
}

/**
 * The version RubyGems gives a semver: Gem::Version turns each "-" into
 * ".pre.", so 0.4.0-beta.1 is 0.4.0.pre.beta.1. Asked of Ruby when there is
 * one, so the printed filename is the one `gem build` writes.
 */
function gemVersion(version, ruby) {
  if (!ruby) return version.replaceAll("-", ".pre.");
  const result = spawnSync("ruby", ["-e", "print Gem::Version.new(ARGV[0]).to_s", version], { cwd: ROOT, encoding: "utf8", env: { ...process.env, ...ruby.env } });
  if (result.status !== 0) fail(`RubyGems rejects ${version}:\n${result.stderr}`);
  return result.stdout;
}

/** Lists the built gem's files and fails unless it carries the library and none of the tests. */
function checkGem(file, ruby) {
  const list = 'require "rubygems/package"; puts Gem::Package.new(ARGV[0]).contents';
  const result = spawnSync("ruby", ["-e", list, file], { cwd: ROOT, encoding: "utf8", env: { ...process.env, ...ruby.env } });
  if (result.status !== 0) fail(`could not list ${file}:\n${result.stderr}`);
  const contents = result.stdout.split("\n").filter(Boolean);
  for (const f of contents) console.log(`  ${f}`);
  const missing = GEM_REQUIRED.filter((f) => !contents.includes(f));
  const extra = contents.filter((f) => GEM_FORBIDDEN.some((prefix) => f.startsWith(prefix)));
  if (missing.length > 0) fail(`the gem is missing ${missing.join(", ")}; check spec.files in packages/ruby/cronwatch.gemspec`);
  if (extra.length > 0) fail(`the gem carries ${extra.join(", ")}; check spec.files in packages/ruby/cronwatch.gemspec`);
  console.log(`${contents.length} files, with ${listed(GEM_REQUIRED)}, and nothing under ${GEM_FORBIDDEN.join(" or ")}.`);
}

/** The edits to make, one per file, after checking every row holds the current version. */
function planEdits(current, next) {
  const edits = new Map();
  for (const { file, pattern } of VERSIONED) {
    const before = edits.get(file)?.after ?? read(file);
    const match = pattern.exec(before);
    if (!match) fail(`${file}: no match for ${pattern}; update VERSIONED in scripts/release.mjs`);
    if (match[2] !== current) fail(`${file} says ${match[2]}, not ${current}; bring it in step first`);
    const after = before.replace(pattern, `$1${next}$3`);
    edits.set(file, { before: edits.get(file)?.before ?? before, after, lines: [...(edits.get(file)?.lines ?? []), [match[0], `${match[1]}${next}${match[3]}`]] });
  }
  return edits;
}

/** Tracked files, outside the table and the regenerated ones, that still mention the old version. */
function strays(current) {
  const skip = new Set([...VERSIONED.map((row) => row.file), "package-lock.json", "scripts/release.mjs"]);
  let out = "";
  try {
    out = git("grep", "-n", "-F", current, "--", ".", ":!conformance/", ":!package-lock.json");
  } catch {
    return [];
  }
  return out.split("\n").filter((line) => line && !skip.has(line.split(":")[0]));
}

/** Whether uv, which runs the Python package's tests, is on the PATH. */
function hasUv() {
  return spawnSync("uv", ["--version"], { cwd: ROOT, encoding: "utf8" }).status === 0;
}

/**
 * A Ruby the gem supports (3.2 or newer) with bundler: the one on PATH, or
 * else the newest such rbenv version. Returns { version, env } or null.
 */
function findRuby() {
  const probe = (cmd, args, env = {}) => spawnSync(cmd, args, { cwd: ROOT, encoding: "utf8", env: { ...process.env, ...env } });
  const supported = (v) => {
    const [major, minor] = v.split(".").map(Number);
    return major > 3 || (major === 3 && minor >= 2);
  };
  const usable = (env) => {
    const ruby = probe("ruby", ["-e", "print RUBY_VERSION"], env);
    return ruby.status === 0 && supported(ruby.stdout) && probe("bundle", ["--version"], env).status === 0 ? ruby.stdout : null;
  };
  const onPath = usable({});
  if (onPath) return { version: onPath, env: {} };
  const rbenv = probe("rbenv", ["versions", "--bare"]);
  if (rbenv.status !== 0) return null;
  const installed = rbenv.stdout.split("\n").filter((v) => /^\d+\.\d+\.\d+$/.test(v) && supported(v));
  installed.sort((a, b) => compareVersions(b, a));
  for (const v of installed) {
    const version = usable({ RBENV_VERSION: v });
    if (version) return { version, env: { RBENV_VERSION: v } };
  }
  return null;
}

function run(label, cmd, args, { cwd = ROOT, env = {} } = {}) {
  const shown = `${Object.entries(env).map(([k, v]) => `${k}=${v} `).join("")}${[cmd, ...args].join(" ")}`;
  console.log(`\n== ${label}\n$ ${cwd === ROOT ? "" : `(cd ${path.relative(ROOT, cwd)}) `}${shown}`);
  const result = spawnSync(cmd, args, { cwd, env: { ...process.env, ...env }, stdio: "inherit" });
  if (result.status !== 0) {
    fail(`${label} failed. Nothing is committed; the working tree holds the bump so far (\`git restore .\` drops it).`);
  }
}

const options = parseArgs(process.argv.slice(2));
const next = options.version;
if (!SEMVER.test(next)) fail(`${next} is not a valid semver version`);
if (next.includes("+")) fail(`${next} has build metadata, which RubyGems rejects; release without the +...`);
const current = JSON.parse(read("packages/sdk/package.json")).version;
if (compareVersions(next, current) <= 0) fail(`${next} is not greater than the current ${current}`);

checkTable();
const branch = git("rev-parse", "--abbrev-ref", "HEAD");
if (branch !== options.branch) fail(`on ${branch}, not ${options.branch}${options.branch === "main" ? " (--branch overrides, for testing)" : ""}`);
const dirty = git("status", "--porcelain", "--untracked-files=no");
if (dirty !== "") fail(`the working tree has changes; commit or stash them first:\n${dirty}`);
const tag = `v${next}`;
if (git("tag", "--list", tag) !== "") fail(`tag ${tag} already exists`);

const edits = planEdits(current, next);
const ruby = options.skipRuby ? null : findRuby();
const uv = !options.skipPython && hasUv();
const gem = gemVersion(next, ruby);
const gemDir = options.dryRun ? path.join(os.tmpdir(), "cronwatch-gem-XXXXXX") : mkdtempSync(path.join(os.tmpdir(), "cronwatch-gem-"));
const gemFile = path.join(gemDir, `cronwatch-${gem}.gem`);
const npm = process.platform === "win32" ? "npm.cmd" : "npm";
const steps = [
  ["Refresh package-lock.json", npm, ["install", "--no-audit", "--no-fund"]],
  ["Regenerate conformance/", npm, ["run", "conformance"]],
  ["Build the SDK", npm, ["run", "build", "--workspace", "packages/sdk"]],
  ["Regenerate the web golden fixture", "node", ["packages/ruby/test/web/golden.mjs"], { env: { TZ: "UTC" } }],
  ["Check", npm, ["run", "check"]],
  ["Build", npm, ["run", "build"]],
  ["Check the packages", npm, ["run", "check:packages"]],
  ...(ruby ? [
    ["Install the gem's bundle", "bundle", ["install", "--quiet"], { cwd: path.join(ROOT, "packages/ruby"), env: ruby.env }],
    ["Test the gem", "bundle", ["exec", "rake", "test"], { cwd: path.join(ROOT, "packages/ruby"), env: ruby.env }],
    ["Build the gem", "gem", ["build", "cronwatch.gemspec", "--output", gemFile], { cwd: path.join(ROOT, "packages/ruby"), env: ruby.env, after: () => checkGem(gemFile, ruby) }],
  ] : []),
  ...(uv ? [["Test the Python package", "uv", ["run", "pytest", "-q"], { cwd: path.join(ROOT, "packages/python") }]] : []),
];
const leftovers = strays(current);

console.log(`Release ${current} -> ${next} on ${branch}${options.dryRun ? " (dry run: nothing is written)" : ""}\n`);
for (const [file, { lines }] of edits) {
  console.log(file);
  for (const [before, after] of lines) console.log(`  - ${before.trim()}\n  + ${after.trim()}`);
}
console.log(`\nRegenerated by the steps below: ${REGENERATED.join(", ")}`);
if (leftovers.length > 0) {
  console.log(`\nStill mentioning ${current} (not in VERSIONED; check whether they should move):`);
  for (const line of leftovers) console.log(`  ${line}`);
}
if (options.skipRuby) console.log("\nSkipping the gem's tests and build (--skip-ruby).");
else if (!ruby) console.log("\nNo Ruby 3.2 or newer with bundler found; skipping the gem's tests and build. CI runs the tests.");
else console.log(`\nRuby ${ruby.version}${ruby.env.RBENV_VERSION ? " (rbenv)" : ""} found; the gem's tests run and the gem is built.`);
if (options.skipPython) console.log("Skipping the Python package's tests (--skip-python).");
else if (!uv) console.log("No uv found; skipping the Python package's tests. CI runs them.");
else console.log("uv found; the Python package's tests run.");
if (gem !== next) console.log(`RubyGems spells ${next} as ${gem}.`);

if (options.dryRun) {
  console.log("\nWould run:");
  for (const [label, cmd, args, opts = {}] of steps) {
    const env = Object.entries(opts.env ?? {}).map(([k, v]) => `${k}=${v} `).join("");
    const cwd = opts.cwd ? `(cd ${path.relative(ROOT, opts.cwd)}) ` : "";
    console.log(`  ${label}: ${cwd}${env}${[cmd, ...args].join(" ")}`);
    if (opts.after) console.log(`    then check it carries ${listed(GEM_REQUIRED)} and nothing under ${GEM_FORBIDDEN.join(" or ")}`);
  }
  console.log(`  Commit: git add -u && git commit -m "Release ${next}"`);
  console.log(`  Tag: git tag -a ${tag} -m "Release ${next}"`);
} else {
  for (const [file, { after }] of edits) writeFileSync(path.join(ROOT, file), after);
  for (const [label, cmd, args, opts = {}] of steps) {
    run(label, cmd, args, opts);
    opts.after?.();
  }
  rmSync(gemDir, { recursive: true, force: true });
  const untracked = git("status", "--porcelain").split("\n").filter((line) => line.startsWith("??"));
  if (untracked.length > 0) console.log(`\nLeft out of the commit (untracked):\n${untracked.join("\n")}`);
  git("add", "-u");
  execFileSync("git", ["commit", "-m", `Release ${next}`], { cwd: ROOT, stdio: "inherit" });
  git("tag", "-a", tag, "-m", `Release ${next}`);
  console.log(`\nCommitted "Release ${next}" and tagged ${tag}. Nothing is pushed or published.`);
}

console.log(`\nNext, by hand:\n  git push origin ${branch} ${tag}`);
for (const { commands } of PUBLISH) for (const command of commands(next, gem)) console.log(`  ${command}`);
for (const old of options.deprecate) {
  for (const name of NPM_PACKAGES) console.log(`  npm deprecate "${name}@${old}" "Upgrade to ${next}"`);
}
