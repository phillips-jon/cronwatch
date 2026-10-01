/**
 * Uses the packages the way a stranger would. Packs @cronwatch/sdk and
 * @cronwatch/mcp (build them first), installs the tarballs into a scratch
 * project, and checks that:
 *
 *   - every SDK entry point loads with import and with require,
 *   - the MCP package loads, and its bin runs,
 *   - tsc accepts both under node16 ESM, node16 CJS (.cts) and bundler
 *     resolution, with skipLibCheck off,
 *   - the entries meant for Cloudflare Workers (the core, D1, pg-cron and
 *     every channel) typecheck with only @cloudflare/workers-types, and
 *     bundle for workerd without a single node: import,
 *   - Are the Types Wrong finds no problems.
 *
 * The scratch project is deleted afterwards; pass --keep to leave it.
 */
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { build } from "esbuild";

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
  "@cronwatch/sdk": ["cronwatch", "Cronwatch", "memory", "formatDuration"],
  "@cronwatch/sdk/sqlite": ["sqlite"],
  "@cronwatch/sdk/postgres": ["postgres"],
  "@cronwatch/sdk/slack": ["slack"],
  "@cronwatch/sdk/discord": ["discord"],
  "@cronwatch/sdk/webhook": ["webhook"],
  "@cronwatch/sdk/anthropic": ["anthropic"],
  "@cronwatch/sdk/d1": ["d1"],
  "@cronwatch/sdk/pg-cron": ["pgCron"],
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
// The entries that must run on Cloudflare Workers with no nodejs_compat:
// everything except the Node drivers, the Node adapter and Anthropic triage.
const NODE_ONLY = ["@cronwatch/sdk/sqlite", "@cronwatch/sdk/postgres", "@cronwatch/sdk/node", "@cronwatch/sdk/anthropic"];
const workersEntries = entries.filter((e) => !NODE_ONLY.includes(e));

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
    `@cloudflare/workers-types@${rootPkg.devDependencies["@cloudflare/workers-types"]}`,
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
  const alias = (name) => {
    const found = bindings.find((b) => b.name === name);
    if (!found) throw new Error(`check-packages: no binding for ${name}`);
    return found.alias;
  };
  const uses = bindings.flatMap(({ keys, alias }) => keys.map((k) => `void ${alias}.${k};`));
  const sdk = alias("@cronwatch/sdk");
  // A stand-in with only the shape of a D1 binding: no @cloudflare/workers-types needed.
  const d1Stub = `{ prepare(): never { throw new Error("no D1 here"); }, async batch() { return []; } }`;
  const typed = [
    `const cw = ${sdk}.cronwatch({ store: ${alias("@cronwatch/sdk/sqlite")}.sqlite({ path: ":memory:" }) });`,
    `const job = cw.job("typed", { schedule: "every 5m", budget: { cost: 1 } });`,
    `const handler: (request: Request) => Promise<Response> = job.handler(async (j) => { j.log("x"); j.metric("cost", 0.1); });`,
    `void handler;`,
    `const summary: Promise<${sdk}.JobSummary[]> = cw.jobs();`,
    `void summary;`,
    `void ${alias("@cronwatch/sdk/postgres")}.postgres({ connectionString: "postgres://x" });`,
    `void ${alias("@cronwatch/sdk/anthropic")}.anthropic({ context: "types" });`,
    `void ${alias("@cronwatch/sdk/d1")}.d1(${d1Stub}, { prefix: "cw_" });`,
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

  // Workers: the entries meant for it, typechecked with the Workers types
  // and no Node types at all, so a declaration that leans on Node fails.
  const workerBindings = bindings.filter((b) => workersEntries.includes(b.name));
  writeFileSync(path.join(dir, "types-workers.ts"), [
    ...workerBindings.map(({ name, alias }) => `import * as ${alias} from "${name}";`),
    ...workerBindings.flatMap(({ keys, alias }) => keys.map((k) => `void ${alias}.${k};`)),
    `interface Env { DB: D1Database; CRONWATCH_TOKEN: string }`,
    `export default {`,
    `  async scheduled(_controller, env, ctx) {`,
    `    const cw = ${sdk}.cronwatch({ store: ${alias("@cronwatch/sdk/d1")}.d1(env.DB), sources: [${alias("@cronwatch/sdk/pg-cron")}.pgCron({ query: async () => ({ rows: [] }) })] });`,
    `    ctx.waitUntil(cw.check());`,
    `  },`,
    `  async fetch(request, env) {`,
    `    const cw = ${sdk}.cronwatch({ store: ${alias("@cronwatch/sdk/d1")}.d1(env.DB) });`,
    `    return cw.routes({ token: env.CRONWATCH_TOKEN }).handler(request);`,
    `  },`,
    `} satisfies ExportedHandler<Env>;`,
  ].join("\n"));
  writeFileSync(path.join(dir, "tsconfig.workers.json"), JSON.stringify({
    compilerOptions: { strict: true, noEmit: true, skipLibCheck: false, target: "ES2022", lib: ["ES2022"], module: "esnext", moduleResolution: "bundler", types: ["@cloudflare/workers-types"] },
    files: ["types-workers.ts"],
  }, null, 2));
  run(path.join(dir, "node_modules/.bin/tsc"), ["-p", "tsconfig.workers.json"], dir);
  console.log("tsc tsconfig.workers.json: ok");

  // Workers: bundle the same entries as wrangler would (browser platform,
  // workerd conditions) and fail on any Node built-in, with or without node:.
  writeFileSync(path.join(dir, "worker.mjs"), [
    ...workerBindings.map(({ name, alias }) => `import * as ${alias} from "${name}";`),
    `export default [${workerBindings.map((b) => b.alias).join(", ")}];`,
  ].join("\n"));
  const nodeImports = [];
  await build({
    absWorkingDir: dir,
    entryPoints: ["worker.mjs"],
    bundle: true,
    write: false,
    format: "esm",
    platform: "browser",
    conditions: ["workerd", "worker", "browser"],
    logLevel: "silent",
    plugins: [{
      name: "no-node",
      setup(b) {
        b.onResolve({ filter: /^node:/ }, (args) => {
          nodeImports.push(`${args.path} from ${path.relative(dir, args.importer)}`);
          return { path: args.path, external: true };
        });
      },
    }],
  });
  if (nodeImports.length > 0) throw new Error(`the Workers entries import Node built-ins: ${nodeImports.join(", ")}`);
  console.log(`esbuild workerd bundle of ${workerBindings.length} entries: ok`);
  console.log("\ncheck-packages: clean");
} finally {
  if (keep) console.log(`kept ${dir}`);
  else rmSync(dir, { recursive: true, force: true });
}
