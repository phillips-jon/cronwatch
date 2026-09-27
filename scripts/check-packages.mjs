/**
 * Uses the packages the way a stranger would. Packs @cronwatch/sdk and
 * @cronwatch/mcp (build them first), installs the tarballs into a scratch
 * project, and checks that:
 *
 *   - every SDK entry point loads with import and with require,
 *   - the MCP package loads, and its bin runs,
 *   - tsc accepts both under node16 ESM, node16 CJS (.cts) and bundler
 *     resolution, with skipLibCheck off,
 *   - Are the Types Wrong finds no problems.
 *
 * The scratch project is deleted afterwards; pass --keep to leave it.
 */
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

const ROOT = process.cwd();
const keep = process.argv.includes("--keep");
const sdkPkg = JSON.parse(readFileSync(path.join(ROOT, "packages/sdk/package.json"), "utf8"));
const rootPkg = JSON.parse(readFileSync(path.join(ROOT, "package.json"), "utf8"));
const npm = process.platform === "win32" ? "npm.cmd" : "npm";

function run(cmd, args, cwd) {
  console.log(`$ ${[cmd, ...args].join(" ")}`);
  execFileSync(cmd, args, { cwd, stdio: "inherit" });
}

// Every subpath the SDK exports, as the names a consumer imports.
const entries = Object.keys(sdkPkg.exports)
  .filter((k) => k !== "./package.json")
  .map((k) => (k === "." ? "@cronwatch/sdk" : `@cronwatch/sdk/${k.slice(2)}`));
// What each entry must export, so a load that "works" but is empty still fails.
const expected = {
  "@cronwatch/sdk": ["cronwatch", "memory", "createRoutes", "formatDuration"],
  "@cronwatch/sdk/sqlite": ["sqlite"],
  "@cronwatch/sdk/postgres": ["postgres"],
  "@cronwatch/sdk/slack": ["slack"],
  "@cronwatch/sdk/discord": ["discord"],
  "@cronwatch/sdk/webhook": ["webhook"],
  "@cronwatch/sdk/anthropic": ["anthropic"],
  "@cronwatch/sdk/d1": ["d1"],
  "@cronwatch/sdk/pg-cron": ["pgCron"],
  // Appended, so the m<index> aliases below keep pointing at the same entries.
  "@cronwatch/sdk/resend": ["resend"],
  "@cronwatch/sdk/postmark": ["postmark"],
  "@cronwatch/sdk/sendgrid": ["sendgrid"],
  "@cronwatch/sdk/mailgun": ["mailgun"],
  "@cronwatch/sdk/ses": ["ses"],
  "@cronwatch/sdk/twilio": ["twilio"],
  "@cronwatch/sdk/sentry": ["sentry"],
  "@cronwatch/sdk/honeybadger": ["honeybadger"],
  "@cronwatch/sdk/datadog": ["datadog"],
  "@cronwatch/sdk/rollbar": ["rollbar"],
  "@cronwatch/sdk/bugsnag": ["bugsnag"],
  "@cronwatch/sdk/newrelic": ["newrelic"],
  "@cronwatch/sdk/node": ["toNodeHandler", "toKoaMiddleware", "toRequest", "writeResponse"],
};
for (const e of entries) {
  if (!expected[e]) throw new Error(`check-packages: add ${e} to the expected exports`);
}

// Are the Types Wrong. The MCP package is ESM only by design.
run("npx", ["attw", "--pack", "packages/sdk"], ROOT);
run("npx", ["attw", "--pack", "packages/mcp", "--profile", "esm-only"], ROOT);

const dir = mkdtempSync(path.join(tmpdir(), "cronwatch-packages-"));
try {
  run(npm, ["pack", "--workspace", "packages/sdk", "--workspace", "packages/mcp", "--pack-destination", dir], ROOT);
  const tarballs = readdirSync(dir).filter((f) => f.endsWith(".tgz")).map((f) => path.join(dir, f));
  if (tarballs.length !== 2) throw new Error(`expected two tarballs, got ${tarballs.join(", ")}`);
  for (const t of tarballs) {
    const listing = execFileSync("tar", ["-tzf", t], { encoding: "utf8" });
    if (!listing.split("\n").includes("package/LICENSE")) throw new Error(`${path.basename(t)} has no LICENSE`);
  }

  // The optional peers a consumer of every entry would add, at the versions this repo tests with.
  const dev = sdkPkg.devDependencies;
  const peers = ["better-sqlite3", "pg", "@anthropic-ai/sdk", "@types/better-sqlite3", "@types/pg", "@types/node"];
  writeFileSync(path.join(dir, "package.json"), JSON.stringify({ name: "scratch", private: true, type: "module" }, null, 2));
  run(npm, [
    "install", "--no-audit", "--no-fund", "--no-package-lock",
    ...tarballs,
    ...peers.map((p) => `${p}@${dev[p]}`),
    `typescript@${dev.typescript ?? rootPkg.devDependencies?.typescript}`,
  ], dir);

  // Runtime: ESM import and CJS require of every entry.
  const checks = Object.entries(expected);
  writeFileSync(path.join(dir, "esm.mjs"), [
    `const expected = ${JSON.stringify(checks)};`,
    `for (const [name, keys] of expected) {`,
    `  const mod = await import(name);`,
    `  for (const k of keys) if (typeof mod[k] !== "function") throw new Error(\`import \${name}: no \${k}\`);`,
    `}`,
    `const mcp = await import("@cronwatch/mcp");`,
    `for (const k of ["createServer", "ApiClient", "ApiError"]) if (typeof mcp[k] !== "function") throw new Error(\`import @cronwatch/mcp: no \${k}\`);`,
    `const { cronwatch } = await import("@cronwatch/sdk");`,
    `const { sqlite } = await import("@cronwatch/sdk/sqlite");`,
    `const cw = cronwatch({ store: sqlite({ path: ":memory:" }), alerts: [] });`,
    `await cw.job("scratch").run((job) => job.log("hello"));`,
    `const [run] = await cw.runs("scratch");`,
    `if (run?.status !== "ok" || run.output !== "hello") throw new Error("sqlite run was not recorded");`,
    `await cw.close();`,
    `console.log("esm: ok");`,
  ].join("\n"));
  writeFileSync(path.join(dir, "cjs.cjs"), [
    `const expected = ${JSON.stringify(checks)};`,
    `for (const [name, keys] of expected) {`,
    `  const mod = require(name);`,
    `  for (const k of keys) if (typeof mod[k] !== "function") throw new Error(\`require \${name}: no \${k}\`);`,
    `}`,
    `console.log("cjs: ok");`,
  ].join("\n"));
  run("node", ["esm.mjs"], dir);
  run("node", ["cjs.cjs"], dir);
  const help = execFileSync(path.join(dir, "node_modules/.bin/cronwatch-mcp"), ["--help"], { encoding: "utf8" });
  if (!help.includes("CRONWATCH_URL")) throw new Error("cronwatch-mcp --help printed something unexpected");
  console.log("bin: ok");

  // Types: one file per module kind, each touching every entry.
  const bindings = checks.map(([name, keys], i) => ({ name, keys, alias: `m${i}` }));
  const uses = bindings.flatMap(({ keys, alias }) => keys.map((k) => `void ${alias}.${k};`));
  const typed = [
    `const cw = m0.cronwatch({ store: m1.sqlite({ path: ":memory:" }) });`,
    `const job = cw.job("typed", { schedule: "every 5m", budget: { cost: 1 } });`,
    `const handler: (request: Request) => Promise<Response> = job.handler(async (j) => { j.log("x"); j.metric("cost", 0.1); });`,
    `void handler;`,
    `const summary: Promise<m0.JobSummary[]> = cw.jobs();`,
    `void summary;`,
    `void m2.postgres({ connectionString: "postgres://x" });`,
    `void m6.anthropic({ context: "types" });`,
    // A stand-in with only the shape of a D1 binding: no @cloudflare/workers-types needed.
    `void ${bindings.find((b) => b.name === "@cronwatch/sdk/d1").alias}.d1({ prepare(): never { throw new Error("no D1 here"); }, async batch() { return []; } }, { prefix: "cw_" });`,
    `const server = mcp.createServer({ baseUrl: "https://example.com/cronwatch", token: null });`,
    `void server;`,
  ];
  writeFileSync(path.join(dir, "types-esm.ts"), [
    ...bindings.map(({ name, alias }) => `import * as ${alias} from "${name}";`),
    `import * as mcp from "@cronwatch/mcp";`,
    ...uses,
    ...typed,
    `export {};`,
  ].join("\n"));
  writeFileSync(path.join(dir, "types-cjs.cts"), [
    ...bindings.map(({ name, alias }) => `import ${alias} = require("${name}");`),
    ...uses,
    ...typed.filter((l) => !l.includes("mcp.") && l !== "void server;"),
    `export {};`,
  ].join("\n"));
  const base = { strict: true, noEmit: true, skipLibCheck: false, target: "ES2022", types: ["node"] };
  const configs = {
    "tsconfig.node16.json": { compilerOptions: { ...base, module: "node16", moduleResolution: "node16" }, files: ["types-esm.ts", "types-cjs.cts"] },
    "tsconfig.bundler.json": { compilerOptions: { ...base, module: "esnext", moduleResolution: "bundler" }, files: ["types-esm.ts"] },
  };
  for (const [file, config] of Object.entries(configs)) {
    writeFileSync(path.join(dir, file), JSON.stringify(config, null, 2));
    run(path.join(dir, "node_modules/.bin/tsc"), ["-p", file], dir);
    console.log(`tsc ${file}: ok`);
  }
  console.log("\ncheck-packages: clean");
} finally {
  if (keep) console.log(`kept ${dir}`);
  else rmSync(dir, { recursive: true, force: true });
}
