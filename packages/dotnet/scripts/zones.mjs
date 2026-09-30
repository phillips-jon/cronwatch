// Writes src/Cronwatch/Internal/Cron/ZoneNames.cs: every IANA zone name,
// aliases included, that Node's Intl (and so croner) accepts, spelled as the
// database spells it. The .NET port matches a zone name against this list
// without regard to case, as Intl does, and asks TimeZoneInfo for the name as
// the list spells it, since TimeZoneInfo on Linux and macOS matches case.
//
// The names come from a tzdata.zi (the compiled source of the IANA database,
// every Zone and Link line), by default the system's; a newer one can be given:
//
//   node packages/dotnet/scripts/zones.mjs [path/to/tzdata.zi]
//
// Run it again when the IANA database adds or renames a zone.
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const source = process.argv[2] ?? "/usr/share/zoneinfo/tzdata.zi";
const text = readFileSync(source, "utf8");
const version = /^# version (\S+)/m.exec(text)?.[1] ?? "unknown";

const names = new Set();
for (const line of text.split("\n")) {
  const parts = line.trim().split(/\s+/);
  if (parts[0] === "Z") names.add(parts[1]);
  else if (parts[0] === "L") names.add(parts[2]);
}

const accepted = [...names].filter((name) => {
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: name });
    return true;
  } catch {
    return false;
  }
});
accepted.sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));

const out = [
  "// Written by packages/dotnet/scripts/zones.mjs; do not edit by hand.",
  `// From tzdata ${version}, filtered by Node ${process.version} (ICU tz ${process.versions.tz}).`,
  "namespace Cronwatch.Internal;",
  "",
  "/// <summary>Every IANA zone name Intl accepts, aliases included, as the database spells it.</summary>",
  "internal static class ZoneNames",
  "{",
  "    /// <summary>The names, sorted ordinally.</summary>",
  "    public static readonly string[] All =",
  "    [",
  ...accepted.map((name) => `        "${name}",`),
  "    ];",
  "}",
  "",
];
const file = path.join(here, "../src/Cronwatch/Internal/Cron/ZoneNames.cs");
writeFileSync(file, out.join("\n"));
console.log(`${accepted.length} of ${names.size} names written to ${path.relative(process.cwd(), file)}`);
