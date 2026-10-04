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
 *   --skip-php         skip the PHP package's tests
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
import { fileURLToPath } from "node:url";
import { addMarkdownChangelog, addReadmeChangelog, addRootChangelog, today } from "./changelogs.mjs";

/**
 * Every place the release version lives. Each pattern captures
 * (before)(version)(after). A row may say `of: "apalis"` (cronwatch-apalis's
 * own version, not the release's) and `form: "minor"` (the version as "X.Y",
 * an install line's constraint, which a prerelease leaves alone); a pattern
 * with the g flag moves every match in its file, and must match at least once.
 */
export const VERSIONED = [
  { file: "packages/sdk/package.json", pattern: /^( {2}"version": ")([^"]+)(")/m },
  // What the SDK reports about itself (VERSION, and GET <base>/api).
  { file: "packages/sdk/src/version.ts", pattern: /^(export const VERSION = ")([^"]+)(")/m },
  { file: "packages/mcp/package.json", pattern: /^( {2}"version": ")([^"]+)(")/m },
  { file: "packages/mcp/package.json", pattern: /^( {4}"@cronwatch\/sdk": ")([^"]+)(")/m },
  { file: "packages/ruby/lib/cronwatch/version.rb", pattern: /^(\s*VERSION = ")([^"]+)(")/m },
  { file: "packages/python/pyproject.toml", pattern: /^(version = ")([^"]+)(")/m },
  { file: "packages/python/src/cronwatch/__init__.py", pattern: /^(__version__ = ")([^"]+)(")/m },
  { file: "packages/php/src/Cronwatch.php", pattern: /^( {4}public const VERSION = ')([^']+)(')/m },
  // The WordPress plugin ships the library's version; wordpress/build.php refuses a zip whose header or readme differ.
  { file: "packages/php/wordpress/cronwatch.php", pattern: /^( \* Version: +)(\S+)()$/m },
  { file: "packages/php/wordpress/readme.txt", pattern: /^(Stable tag: )(\S+)()$/m },
  // The Drupal module and the Craft plugin are released with the library they
  // require; their versions come from their tags, so the library constraint
  // is what moves.
  { file: "packages/php/drupal/composer.json", pattern: /^( {8}"cronwatch\/cronwatch": "\^)([^"]+)(")/m },
  { file: "packages/php/craft/composer.json", pattern: /^( {8}"cronwatch\/cronwatch": "\^)([^"]+)(")/m },
  // A Go module's version is its tag (see PUBLISH); the constant is what the
  // library reports about itself, kept in step with the tag.
  { file: "packages/go/version.go", pattern: /^(const Version = ")([^"]+)(")/m },
  // The scheduler integrations are modules of their own, released with the
  // core under tags of their own (see PUBLISH); each requires the core, and
  // those that convert robfig/cron schedules robfigcron, at the same
  // release. A replace directive points them at the source for development;
  // an app that requires one ignores it and gets these versions.
  // (A requirement is on a require line of its own or in a require block.)
  { file: "packages/go/robfigcron/go.mod", pattern: /^((?:require |\t)cronwatch\.dev\/go v)(\S+)()$/m },
  ...["gocron", "river", "asynq"].flatMap((name) => [
    { file: `packages/go/${name}/go.mod`, pattern: /^((?:require |\t)cronwatch\.dev\/go v)(\S+)()$/m },
    { file: `packages/go/${name}/go.mod`, pattern: /^((?:require |\t)cronwatch\.dev\/go\/robfigcron v)(\S+)()$/m },
  ]),
  // The Rust workspace's crates all take the version from
  // [workspace.package], and require each other at exactly that release
  // through [workspace.dependencies]; cronwatch::VERSION is the package's own.
  { file: "packages/rust/Cargo.toml", pattern: /^(version = ")([^"]+)(")/m },
  { file: "packages/rust/Cargo.toml", pattern: /^(cronwatch = \{ path = "cronwatch", version = "=)([^"]+)(")/m },
  // Except cronwatch-apalis, which stays below 1.0 while apalis 1.0 is a
  // release candidate (packages/rust/DESIGN.md, item 42): its version is its
  // own, the release's below 1.0 and a 0.x line of its own from 1.0
  // (apalisVersion below).
  { file: "packages/rust/cronwatch-apalis/Cargo.toml", pattern: /^(version = ")([^"]+)(")/m, of: "apalis" },
  // The install lines name a minor ("0.10" in Cargo admits 0.10.x, "1.0"
  // every 1.x), so a copied line installs this release or a later
  // compatible one.
  ...["packages/rust/README.md", "packages/rust/cronwatch-sqlx/README.md", "packages/rust/cronwatch-tokio-cron-scheduler/README.md", "packages/rust/cronwatch-apalis/README.md", "site/docs/rust.md", "site/docs/rust-schedulers.md"].map((file) => (
    { file, pattern: /^(cronwatch(?:-sqlx|-tokio-cron-scheduler)? = (?:\{ version = )?")([^"]+)(")/gm, form: "minor" })),
  ...["packages/rust/cronwatch-apalis/README.md", "site/docs/rust-schedulers.md"].map((file) => (
    { file, pattern: /^(cronwatch-apalis = (?:\{ version = )?")([^"]+)(")/gm, form: "minor", of: "apalis" })),
  // The Hex package's version lives in mix.exs alone; Cronwatch.version/0
  // reads it from the application's spec.
  { file: "packages/elixir/mix.exs", pattern: /^(\s*@version ")([^"]+)(")/m },
  // The install line, "~> X.Y", admits every later release below the next
  // major. (landing.html escapes the >.)
  ...["README.md", "packages/elixir/README.md", "site/docs/elixir.md", "site/src/landing.html", "site/src/prompt.txt", "skills/cronwatch/SKILL.md", "site/build.mjs"].map((file) => (
    { file, pattern: /(\{:cronwatch, \\?"~(?:>|&gt;) )([^"\\]+)(\\?")/g, form: "minor" })),
  // The Maven build's version lives in the parent POM's <revision> alone:
  // every module's version is ${revision}, the flatten plugin writes it into
  // the POMs that are published, and Cronwatch.VERSION is read from a
  // resource Maven filters with it.
  { file: "packages/java/pom.xml", pattern: /^(\s*<revision>)([^<]+)(<\/revision>)/m },
  // The README's dependency snippet names the release.
  { file: "packages/java/README.md", pattern: /^( {2}<version>)([^<]+)(<\/version>)/m },
  // The .NET solution's version lives in Directory.Build.props alone: every
  // project inherits it, and CronwatchClient.Version reads it back from the
  // assembly. The README's install line names the release.
  { file: "packages/dotnet/Directory.Build.props", pattern: /^(\s*<Version>)([^<]+)(<\/Version>)/m },
  { file: "packages/dotnet/README.md", pattern: /^(dotnet add package Cronwatch --version )(\S+)()$/m },
  { file: "skills/cronwatch/SKILL.md", pattern: /^(version: )(\S+)()$/m },
];

/**
 * The changelogs a release writes its section into (scripts/changelogs.mjs):
 * the WordPress plugin's readme, whose "= Unreleased =" becomes "= X.Y.Z =",
 * and the Craft plugin's and Drupal module's CHANGELOG.md, whose
 * "## Unreleased" becomes "## X.Y.Z - <today>". A file with no notes written
 * ahead gets a placeholder section, with a reminder to write better notes.
 * The project's CHANGELOG.md is turned the same way, but holds the
 * release's notes, so the release refuses to run without its Unreleased
 * section.
 */
const README_CHANGELOG = "packages/php/wordpress/readme.txt";
const MARKDOWN_CHANGELOGS = ["packages/php/craft/CHANGELOG.md", "packages/php/drupal/CHANGELOG.md"];
const ROOT_CHANGELOG = "CHANGELOG.md";

/** How each package ships, printed after the release commit, in order. Given the semver and the RubyGems version. */
const PUBLISH = [
  { dir: "packages/sdk", commands: () => ["npm publish --workspace packages/sdk --access public"] },
  { dir: "packages/mcp", commands: () => ["npm publish --workspace packages/mcp --access public"] },
  { dir: "packages/ruby", commands: (v, gem) => [`(cd packages/ruby && gem build cronwatch.gemspec && gem push cronwatch-${gem}.gem)`] },
  { dir: "packages/python", commands: (v) => [`# packages/python: the pushed tag v${v} is published to PyPI by .github/workflows/pypi.yml (trusted publishing, once PYPI_ENABLED is true)`] },
  // Packagist publishes from git tags, and reads composer.json from a
  // repository's root: pushing the tag starts .github/workflows/php-split.yml,
  // which pushes packages/php and the tag to the split repository Packagist
  // watches, once PHP_SPLIT_ENABLED is on (packages/php/DESIGN.md, Releasing).
  // The WordPress plugin is not in the plugin directory yet: the same tag
  // starts .github/workflows/wordpress-zip.yml, which builds its zip and
  // attaches it to the tag's GitHub release, making the release if needed.
  { dir: "packages/php", commands: (v) => [
    `# packages/php: the pushed tag v${v} is split to its own repository by .github/workflows/php-split.yml (packages/php/DESIGN.md, Releasing)`,
    `# packages/php/drupal and packages/php/craft: the same tag is split to drupal.org's repository (as ${v}) and the Craft plugin's by .github/workflows/php-plugins-split.yml; then make the drupal.org release from the ${v} tag`,
    `# packages/php/wordpress: the same tag builds the plugin's zip and attaches it to the GitHub release v${v} (made if missing) as cronwatch-${v}.zip and cronwatch.zip, by .github/workflows/wordpress-zip.yml`,
  ] },
  // Go modules publish by tag: a module in a subdirectory is versioned by a
  // tag with that prefix, so the release commit also gets packages/go/vX.Y.Z,
  // and the Go proxy serves it once anyone asks (packages/go/DESIGN.md,
  // Releasing). The scheduler integrations nested in it are modules of
  // their own, each tagged with its directory at the same version.
  // packages/go/sqltest and packages/go/examples hold tests and examples
  // only and are never tagged.
  { dir: "packages/go", commands: (v) => [
    ...["", "robfigcron/", "gocron/", "river/", "asynq/"].map((sub) =>
      `git tag -a packages/go/${sub}v${v} -m "Release ${v} (Go${sub ? `, ${sub.slice(0, -1)}` : ""})" v${v}^{} && git push origin packages/go/${sub}v${v}`),
    `# packages/go: then GOPROXY=https://proxy.golang.org go list -m cronwatch.dev/go@v${v} cronwatch.dev/go/robfigcron@v${v} cronwatch.dev/go/gocron@v${v} cronwatch.dev/go/river@v${v} cronwatch.dev/go/asynq@v${v} makes the proxy fetch them (once cronwatch.dev serves the go-import tags)`,
  ] },
  // crates.io reads each crate from the tarball cargo uploads, so the crates
  // need no tag of their own. Published by hand for now (packages/rust/DESIGN.md,
  // Crate name and releases); Cargo 1.90 or newer publishes a workspace's
  // crates in dependency order.
  { dir: "packages/rust", commands: (v) => [`# packages/rust: the pushed tag v${v} is published to crates.io by .github/workflows/crates.yml (trusted publishing, once CRATES_ENABLED is true), cronwatch-apalis at its own version (its Cargo.toml); by hand, (cd packages/rust && cargo publish --workspace --exclude cronwatch-webserver --exclude cronwatch-example-crontab)`] },
  // Hex reads a package from the tarball `mix hex.publish` uploads, so the
  // package needs no tag of its own. .github/workflows/hex.yml publishes it
  // and its docs from the pushed tag, with a package-scoped API key, once
  // HEX_ENABLED is true (packages/elixir/DESIGN.md, Package name and releases).
  { dir: "packages/elixir", commands: (v) => [`# packages/elixir: the pushed tag v${v} is published to Hex, with its docs, by .github/workflows/hex.yml (once HEX_ENABLED is true); by hand, (cd packages/elixir && mix hex.publish)`] },
  // Maven Central reads the artifacts from the bundle the release profile
  // uploads to the Central Publisher Portal, so they need no tag of their
  // own. The first release is published by hand, with a signing key and a
  // Portal token in ~/.m2/settings.xml, and checked in the Portal before it
  // is published; after it, .github/workflows/java.yml publishes the pushed
  // tag, with a Portal token and a signing subkey from the maven
  // environment, once MAVEN_ENABLED is true (packages/java/DESIGN.md,
  // Releasing).
  { dir: "packages/java", commands: (v) => [`# packages/java: the pushed tag v${v} is published to Maven Central by .github/workflows/java.yml (once MAVEN_ENABLED is true, which it is not for the first release); by hand, (cd packages/java && ./mvnw -B -P release deploy), then check the validated deployment of ${v} in the Central Publisher Portal and press Publish (packages/java/DESIGN.md, Releasing)`] },
  // NuGet reads each package from the .nupkg pushed to it, so the solution
  // needs no tag of its own. .github/workflows/nuget.yml packs the five
  // packages from the pushed tag and, once its reviewer approves, pushes
  // them with trusted publishing, the core first so no package is listed
  // before one it needs, once NUGET_ENABLED is true
  // (packages/dotnet/DESIGN.md, Releasing).
  { dir: "packages/dotnet", commands: (v) => [`# packages/dotnet: the pushed tag v${v} is published to nuget.org by .github/workflows/nuget.yml (trusted publishing, once NUGET_ENABLED is true); by hand, (cd packages/dotnet && dotnet pack -c Release -o artifacts/packages && bash scripts/check-packages.sh artifacts/packages && for p in Cronwatch Cronwatch.Hosting Cronwatch.AspNetCore Cronwatch.Hangfire Cronwatch.Quartz; do dotnet nuget push artifacts/packages/$p.${v}.nupkg --source https://api.nuget.org/v3/index.json --skip-duplicate --api-key <a key scoped to Cronwatch*>; done)`] },
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
  const options = { version: null, dryRun: false, branch: "main", skipRuby: false, skipPython: false, skipPhp: false, deprecate: [] };
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
    else if (arg === "--skip-php") options.skipPhp = true;
    else if (arg === "--branch") options.branch = value();
    else if (arg === "--deprecate") options.deprecate.push(value());
    else if (arg === "--help" || arg === "-h") {
      console.log("usage: node scripts/release.mjs <version> [--dry-run] [--branch <name>] [--skip-ruby] [--skip-python] [--skip-php] [--deprecate <old>]");
      process.exit(0);
    } else if (arg.startsWith("--")) fail(`unknown option ${arg}`);
    else if (options.version === null) options.version = arg.replace(/^v/, "");
    else fail(`unexpected argument ${arg}`);
  }
  if (options.version === null) fail("usage: node scripts/release.mjs <version> [--dry-run] [--branch <name>] [--skip-ruby] [--skip-python] [--skip-php] [--deprecate <old>]");
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

/** "X.Y" of a version: what an install line's constraint names. */
export function minorOf(version) {
  const [, major, minor] = SEMVER.exec(version);
  return `${major}.${minor}`;
}

/**
 * cronwatch-apalis's version for a release from `current` to `next`, given
 * its own `apalis` now. Below 1.0 it is the release's. From 1.0 it keeps a
 * 0.x line of its own: a release that moves the major or minor moves its
 * minor, a patch release its patch, and a prerelease carries the same
 * suffix (1.0.0-beta.1 after 0.10.0 makes it 0.11.0-beta.1, then 1.0.0
 * makes it 0.11.0).
 */
export function apalisVersion(apalis, current, next) {
  const [, nMajor, nMinor, nPatch, nPre] = SEMVER.exec(next);
  if (nMajor === "0") return next;
  const [, aMajor, aMinor, aPatch, aPre] = SEMVER.exec(apalis);
  const [, cMajor, cMinor, cPatch] = SEMVER.exec(current);
  if (aMajor !== "0") throw new Error(`cronwatch-apalis is at ${apalis}: once apalis 1.0 is final, put it back on version.workspace and drop its rows from VERSIONED`);
  let base;
  // Only the prerelease moved, or the crate's own prerelease is finished first.
  if ((cMajor === nMajor && cMinor === nMinor && cPatch === nPatch) || aPre !== undefined) base = [aMajor, aMinor, aPatch];
  else if (cMajor !== nMajor || cMinor !== nMinor) base = [aMajor, Number(aMinor) + 1, 0];
  else base = [aMajor, aMinor, Number(aPatch) + 1];
  return `${base.join(".")}${nPre === undefined ? "" : `-${nPre}`}`;
}

/**
 * The edits to make, one per file, after checking every row holds the
 * current version. Throws when a row has no match or holds another version.
 */
export function planEdits(rows, readFile, current, next) {
  const apalisRow = rows.find((row) => row.of === "apalis" && row.form === undefined);
  const apalis = apalisRow && apalisRow.pattern.exec(readFile(apalisRow.file))?.[2];
  if (apalisRow && !apalis) throw new Error(`${apalisRow.file}: no match for ${apalisRow.pattern}; update VERSIONED in scripts/release.mjs`);
  if (apalis && SEMVER.exec(current)[1] === "0" && apalis !== current) throw new Error(`${apalisRow.file} says ${apalis}, not ${current}; below 1.0 cronwatch-apalis is released at the release's version`);
  const versions = { release: [current, next], apalis: apalis ? [apalis, apalisVersion(apalis, current, next)] : undefined };
  const prerelease = (v) => SEMVER.exec(v)[4] !== undefined;
  const edits = new Map();
  for (const { file, pattern, of = "release", form } of rows) {
    const [was, will] = versions[of];
    // An install line names the newest stable minor: a prerelease leaves it
    // alone, and while the current version is one it may name any.
    const expected = form === "minor" ? (prerelease(was) ? null : minorOf(was)) : was;
    const value = form === "minor" ? (prerelease(will) ? null : minorOf(will)) : will;
    const before = edits.get(file)?.after ?? readFile(file);
    const matches = pattern.global ? [...before.matchAll(pattern)] : [pattern.exec(before)].filter(Boolean);
    if (matches.length === 0) throw new Error(`${file}: no match for ${pattern}; update VERSIONED in scripts/release.mjs`);
    for (const match of matches) if (expected !== null && match[2] !== expected) throw new Error(`${file} says ${match[2]}, not ${expected}; bring it in step first`);
    const after = before.replace(pattern, (_, head, version, tail) => `${head}${value ?? version}${tail}`);
    const lines = matches.map((match) => [match[0], `${match[1]}${value ?? match[2]}${match[3]}`]);
    edits.set(file, { before: edits.get(file)?.before ?? before, after, lines: [...(edits.get(file)?.lines ?? []), ...lines] });
  }
  return edits;
}

/**
 * Tracked files, outside the table and the regenerated ones, that still
 * mention the old version, or name its minor the way an install line does
 * (`cronwatch = "X.Y"` in Cargo, `{:cronwatch, "~> X.Y"}` on Hex).
 */
function strays(current) {
  const skip = new Set([...VERSIONED.map((row) => row.file), ...MARKDOWN_CHANGELOGS, ROOT_CHANGELOG, "package-lock.json", "scripts/release.mjs", "scripts/release.test.mjs"]);
  const minor = minorOf(current).replace(".", "\\.");
  const found = [];
  for (const args of [["-F", current], ["-E", `cronwatch[a-z-]* = (\\{ version = )?"${minor}"|\\{:cronwatch, \\\\?"~(>|&gt;) ${minor}`]]) {
    try {
      found.push(...git("grep", "-n", ...args, "--", ".", ":!conformance/", ":!package-lock.json").split("\n"));
    } catch {}
  }
  return [...new Set(found)].filter((line) => line && !skip.has(line.split(":")[0]));
}

/** Whether uv, which runs the Python package's tests, is on the PATH. */
function hasUv() {
  return spawnSync("uv", ["--version"], { cwd: ROOT, encoding: "utf8" }).status === 0;
}

/** Whether a PHP the PHP package supports (8.2 or newer) and Composer, which run its tests, are on the PATH. */
function hasPhp() {
  const php = spawnSync("php", ["-r", "exit(PHP_VERSION_ID >= 80200 ? 0 : 1);"], { cwd: ROOT, encoding: "utf8" });
  return php.status === 0 && spawnSync("composer", ["--version"], { cwd: ROOT, encoding: "utf8" }).status === 0;
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

/** Run as a script (not imported by its tests): cut the release. */
function main() {
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

  let edits;
  try {
    edits = planEdits(VERSIONED, read, current, next);
  } catch (error) {
    fail(error.message);
  }
  {
    const readme = edits.get(README_CHANGELOG);
    if (!readme) fail(`${README_CHANGELOG} is not in VERSIONED`);
    const date = today();
    const changes = [[README_CHANGELOG, readme, (text) => addReadmeChangelog(text, next, README_CHANGELOG), '"= Unreleased ="']];
    for (const file of MARKDOWN_CHANGELOGS) {
      if (!edits.has(file)) { const text = read(file); edits.set(file, { before: text, after: text, lines: [] }); }
      changes.push([file, edits.get(file), (text) => addMarkdownChangelog(text, next, date, file), '"## Unreleased"']);
    }
    {
      const text = read(ROOT_CHANGELOG);
      edits.set(ROOT_CHANGELOG, { before: text, after: text, lines: [] });
      changes.push([ROOT_CHANGELOG, edits.get(ROOT_CHANGELOG), (text) => addRootChangelog(text, next, date, ROOT_CHANGELOG), '"## Unreleased"']);
    }
    for (const [file, edit, add, heading] of changes) {
      let result;
      try {
        result = add(edit.after);
      } catch (error) {
        fail(error.message);
      }
      edit.after = result.text;
      edit.lines.push([`Changelog`, result.change]);
      if (!result.written) console.log(`Note: ${file} has no ${heading} section, so the release adds a placeholder changelog entry; edit it before tagging, or write the notes under ${heading} next time.\n`);
    }
  }
  const ruby = options.skipRuby ? null : findRuby();
  const uv = !options.skipPython && hasUv();
  const php = !options.skipPhp && hasPhp();
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
    ...(php ? [
      ["Install the PHP package's dev dependencies", "composer", ["install", "--no-interaction", "--quiet"], { cwd: path.join(ROOT, "packages/php") }],
      ["Test the PHP package", "php", ["vendor/bin/phpunit"], { cwd: path.join(ROOT, "packages/php") }],
    ] : []),
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
  else if (!ruby) console.log("\nNo Ruby 3.2 or newer with bundler found; skipping the gem's tests and build. CI runs the tests; wait for it to pass before pushing the gem.");
  else console.log(`\nRuby ${ruby.version}${ruby.env.RBENV_VERSION ? " (rbenv)" : ""} found; the gem's tests run and the gem is built.`);
  if (options.skipPython) console.log("Skipping the Python package's tests (--skip-python).");
  else if (!uv) console.log("No uv found; skipping the Python package's tests. CI runs them, and pypi.yml waits for CI to pass before it publishes.");
  else console.log("uv found; the Python package's tests run.");
  if (options.skipPhp) console.log("Skipping the PHP package's tests (--skip-php).");
  else if (!php) console.log("No PHP 8.2 or newer with Composer found; skipping the PHP package's tests. CI runs them, and the PHP splits wait for CI to pass before they push.");
  else console.log("PHP and Composer found; the PHP package's tests run.");
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

  console.log(`\nNext, by hand:\n  git push origin ${branch} ${tag}\n  # The tag's publish workflows wait for CI to pass on this commit (.github/workflows/ci-passed.yml); publish the rest by hand once it has.`);
  for (const { commands } of PUBLISH) for (const command of commands(next, gem)) console.log(`  ${command}`);
  for (const old of options.deprecate) {
    for (const name of NPM_PACKAGES) console.log(`  npm deprecate "${name}@${old}" "Upgrade to ${next}"`);
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
