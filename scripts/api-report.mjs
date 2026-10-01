/**
 * The public API of the TypeScript packages, written as plain text so a
 * change to it is a line of the diff. For each entry point of
 * @cronwatch/sdk and @cronwatch/mcp (the entries their tsup.config.ts
 * builds with declarations), every export with its signature: functions,
 * classes with their public members, interfaces with their members, type
 * aliases, constants, and which of them are deprecated.
 *
 *   node scripts/api-report.mjs          rewrites packages/<name>/api.txt
 *   node scripts/api-report.mjs --check  fails if either file is stale
 *
 * A failing check means the public API changed: rerun without --check,
 * read the diff, and record the change in CHANGELOG.md (under Unreleased)
 * in the same commit. Removing or changing a line is a breaking change,
 * which waits for a major release (site/docs/stability.md).
 */
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import ts from "typescript";

const ROOT = path.resolve(import.meta.dirname, "..");
const PACKAGES = [
  { dir: "packages/sdk", name: "@cronwatch/sdk" },
  { dir: "packages/mcp", name: "@cronwatch/mcp", dts: true },
];

/** The entries a tsup.config.ts builds declarations for, as [subpath, source file]. */
function entries(dir, dtsOnly) {
  const config = readFileSync(path.join(ROOT, dir, "tsup.config.ts"), "utf8");
  const block = dtsOnly ? config.match(/dts:\s*\{\s*entry:\s*\{([^}]*)\}/)[1] : config.match(/entry:\s*\{([^}]*)\}/)[1];
  return [...block.matchAll(/(?:"([^"]+)"|([\w-]+)):\s*"([^"]+\.ts)"/g)].map((m) => [m[1] ?? m[2], path.join(ROOT, dir, m[3])]);
}

const FLAGS = ts.TypeFormatFlags.NoTruncation | ts.TypeFormatFlags.WriteArrayAsGenericType | ts.TypeFormatFlags.UseSingleQuotesForStringLiteralType;

function report(pkg) {
  const list = entries(pkg.dir, pkg.dts);
  const program = ts.createProgram(
    list.map(([, file]) => file),
    { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext, moduleResolution: ts.ModuleResolutionKind.Bundler, strict: true, skipLibCheck: true, noEmit: true, types: ["node"] },
  );
  const checker = program.getTypeChecker();
  const type = (t, flags = 0) => checker.typeToString(t, undefined, FLAGS | flags);
  const deprecated = (symbol) => (symbol.getJsDocTags(checker).some((tag) => tag.name === "deprecated") ? " (deprecated)" : "");
  const isPublic = (decl) => !decl || !(ts.getCombinedModifierFlags(decl) & (ts.ModifierFlags.Private | ts.ModifierFlags.Protected)) && !(decl.name && ts.isPrivateIdentifier(decl.name));
  const typeParams = (decl) => (decl?.typeParameters?.length ? `<${decl.typeParameters.map((p) => p.getText()).join(", ")}>` : "");

  /** One member of an interface or class, as "name?: type" or "name(args): ret" per signature. */
  function member(prop, at, prefix = "") {
    const decl = prop.valueDeclaration ?? prop.declarations?.[0];
    if (!isPublic(decl) || (decl && decl.getSourceFile().fileName.includes("/node_modules/"))) return [];
    const t = checker.getTypeOfSymbolAtLocation(prop, at);
    const optional = prop.flags & ts.SymbolFlags.Optional ? "?" : "";
    const readonly = decl && ts.getCombinedModifierFlags(decl) & ts.ModifierFlags.Readonly ? "readonly " : "";
    if (prop.flags & ts.SymbolFlags.Method) {
      return checker.getSignaturesOfType(t, ts.SignatureKind.Call).map((s) => `  ${prefix}${prop.name}${optional}${checker.signatureToString(s, undefined, FLAGS)}${deprecated(prop)}`);
    }
    // A property's written type where it has one, so a type from Node's or
    // the DOM's declarations prints as it is named, not expanded.
    const written = decl && (ts.isPropertySignature(decl) || ts.isPropertyDeclaration(decl)) && decl.type ? decl.type.getText().replace(/\s+/g, " ") : type(t);
    return [`  ${prefix}${readonly}${prop.name}${optional}: ${written}${deprecated(prop)}`];
  }

  const out = [];
  for (const [sub, file] of list) {
    const source = program.getSourceFile(file);
    const moduleSymbol = checker.getSymbolAtLocation(source);
    const lines = [`# ${pkg.name}${sub === "index" ? "" : `/${sub}`}`];
    const exports = checker.getExportsOfModule(moduleSymbol).sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
    for (const exported of exports) {
      const symbol = exported.flags & ts.SymbolFlags.Alias ? checker.getAliasedSymbol(exported) : exported;
      const name = exported.name;
      const dep = deprecated(exported) || deprecated(symbol);
      const decl = symbol.valueDeclaration ?? symbol.declarations?.[0];
      if (symbol.flags & ts.SymbolFlags.Class) {
        lines.push(`class ${name}${typeParams(decl)}${dep}`);
        const statics = checker.getTypeOfSymbolAtLocation(symbol, decl);
        for (const s of statics.getConstructSignatures()) lines.push(`  constructor${checker.signatureToString(s, undefined, FLAGS).replace(/:[^:]*$/, "")}`);
        for (const prop of checker.getPropertiesOfType(statics)) if (prop.name !== "prototype") lines.push(...member(prop, decl, "static "));
        for (const prop of checker.getPropertiesOfType(checker.getDeclaredTypeOfSymbol(symbol))) lines.push(...member(prop, decl));
      } else if (symbol.flags & ts.SymbolFlags.Function) {
        for (const s of checker.getTypeOfSymbolAtLocation(symbol, decl).getCallSignatures()) lines.push(`function ${name}${checker.signatureToString(s, undefined, FLAGS)}${dep}`);
      } else if (symbol.flags & ts.SymbolFlags.Interface) {
        lines.push(`interface ${name}${typeParams(decl)}${dep}`);
        const declared = checker.getDeclaredTypeOfSymbol(symbol);
        for (const s of declared.getCallSignatures()) lines.push(`  ${checker.signatureToString(s, undefined, FLAGS)}`);
        for (const prop of checker.getPropertiesOfType(declared)) lines.push(...member(prop, decl));
      } else if (symbol.flags & ts.SymbolFlags.TypeAlias) {
        lines.push(`type ${name}${typeParams(decl)} = ${type(checker.getDeclaredTypeOfSymbol(symbol), ts.TypeFormatFlags.InTypeAlias)}${dep}`);
      } else if (symbol.flags & ts.SymbolFlags.Variable) {
        // A literal widened (VERSION is a string, not this release's number).
        lines.push(`const ${name}: ${type(checker.getBaseTypeOfLiteralType(checker.getTypeOfSymbolAtLocation(symbol, decl)))}${dep}`);
      } else {
        lines.push(`${ts.SymbolFlags[symbol.flags] ?? "export"} ${name}${dep}`);
      }
    }
    out.push(lines.join("\n"));
  }
  return `${out.join("\n\n")}\n`;
}

const check = process.argv.includes("--check");
let stale = false;
for (const pkg of PACKAGES) {
  const file = path.join(ROOT, pkg.dir, "api.txt");
  const text = report(pkg);
  let old = "";
  try {
    old = readFileSync(file, "utf8");
  } catch {}
  if (old === text) continue;
  if (check) {
    stale = true;
    console.error(`api-report: ${pkg.dir}/api.txt is stale: ${pkg.name}'s public API changed. Run node scripts/api-report.mjs, review the diff and record the change in CHANGELOG.md.`);
  } else {
    writeFileSync(file, text);
    console.log(`api-report: wrote ${pkg.dir}/api.txt`);
  }
}
if (stale) process.exit(1);
