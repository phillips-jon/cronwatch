/**
 * Writes packages/dotnet/src/Cronwatch/Internal/Jsre/JsreCanonicalTable.cs:
 * JavaScript's Canonicalize without the u flag, as Node's own toUpperCase
 * answers it, for every UTF-16 code unit that it changes. A code unit's upper
 * case counts only when it is one code unit, and never when it maps a
 * character outside ASCII onto one inside it (the long s and the Kelvin sign
 * keep themselves), as the specification reads it.
 *
 * .NET's ToUpperInvariant uses simple case mappings and would take, for
 * example, U+1F80 to U+1F88 where JavaScript's full mapping gives two code
 * units and so leaves the character alone; hence a table of the SDK's own
 * runtime's answers.
 *
 *   node packages/dotnet/scripts/canonical.mjs          rewrite the file
 *   node packages/dotnet/scripts/canonical.mjs --print  print it instead
 */
import { writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const pairs = [];
for (let c = 0; c <= 0xffff; c++) {
  const upper = String.fromCharCode(c).toUpperCase();
  let k = c;
  if (upper.length === 1) {
    const u = upper.charCodeAt(0);
    if (!(c >= 128 && u < 128)) k = u;
  }
  if (k !== c) pairs.push([c, k - c]);
}

// Runs of code units a fixed step apart, each moved by the same amount.
const runs = [];
for (let i = 0; i < pairs.length; ) {
  const [c, d] = pairs[i];
  let step = 1;
  if (i + 1 < pairs.length && pairs[i + 1][1] === d && pairs[i + 1][0] - c <= 2) step = pairs[i + 1][0] - c;
  let n = 1;
  while (i + n < pairs.length && pairs[i + n][1] === d && pairs[i + n][0] === c + n * step) n++;
  if (n === 1) step = 1;
  runs.push([c, n, step, d]);
  i += n;
}

const lines = [];
for (let i = 0; i < runs.length; i += 4) {
  lines.push("        " + runs.slice(i, i + 4).map((r) => r.join(", ")).join(", ") + ",");
}

const text = `// Written by packages/dotnet/scripts/canonical.mjs from Node; do not edit.

namespace Cronwatch.Internal;

/// <summary>
/// JavaScript's Canonicalize without the <c>u</c> flag, as runs of code units it changes: each
/// run is its first code unit, how many there are, the step between them and what is added to
/// each.
/// </summary>
internal static class JsreCanonicalTable
{
    public static readonly int[] Runs =
    [
${lines.join("\n")}
    ];
}
`;

if (process.argv.includes("--print")) {
  process.stdout.write(text);
} else {
  const here = path.dirname(fileURLToPath(import.meta.url));
  writeFileSync(path.join(here, "../src/Cronwatch/Internal/Jsre/JsreCanonicalTable.cs"), text);
}
