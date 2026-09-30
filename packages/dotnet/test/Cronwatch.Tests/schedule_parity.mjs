// Answers the cases of the .NET port's CronerParityTests with the SDK (the built packages/sdk/dist,
// so croner itself): for each { schedule, timezone, from, count }, the error
// parseSchedule throws, or the next `count` fires.
//
//   node schedule_parity.mjs <packages/sdk/dist> <cases.json>
import { readFileSync } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const { nextFire, parseSchedule } = await import(pathToFileURL(path.join(process.argv[2], "index.js")).href);

const cases = JSON.parse(readFileSync(process.argv[3], "utf8"));
const out = cases.map(({ schedule, timezone, from, count }) => {
  let parsed;
  try {
    parsed = parseSchedule(schedule, timezone ?? undefined);
  } catch (error) {
    return { error: error.message };
  }
  const fires = [];
  let t = from;
  try {
    for (let i = 0; i < count; i++) {
      t = nextFire(parsed, t, null);
      fires.push(t);
      if (t === null) break;
    }
  } catch (error) {
    // croner walks by recursion, a year at a time, so a date no month has
    // (February 30) runs out of stack before it reaches the year 3000.
    return { fires, throws: error.message };
  }
  return { fires };
});
process.stdout.write(JSON.stringify(out));
