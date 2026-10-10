import type { JobDefinition, StoredJob, StoredJobDefinition } from "./types.js";

/** A definition as a store can hold it: `expect` becomes a description. */
export function toStored(def: JobDefinition): StoredJobDefinition {
  const { expect, ...rest } = def;
  const stored: StoredJobDefinition = { ...rest };
  if (expect !== undefined) {
    stored.expect =
      typeof expect === "string" ? `contains ${JSON.stringify(expect)}`
      : expect instanceof RegExp ? `matches ${expect.toString()}`
      : "custom function";
  }
  return stored;
}

export function checkExpectation(expect: JobDefinition["expect"], output: string | null): string | null {
  if (expect === undefined) return null;
  const text = output ?? "";
  if (typeof expect === "string") {
    return text.includes(expect) ? null : `Output did not contain ${JSON.stringify(expect)}`;
  }
  if (expect instanceof RegExp) {
    expect.lastIndex = 0; // a /g or /y pattern would otherwise resume where the last run stopped
    return expect.test(text) ? null : `Output did not match ${expect.toString()}`;
  }
  let ok = false;
  try {
    ok = expect(text);
  } catch (error) {
    return `Output check threw: ${(error as Error).message}`;
  }
  return ok ? null : "Output did not pass the expect() check";
}

/**
 * A stored job as the client reads it, so a foreign, hand-edited, or damaged
 * row affects only its own job. A definition that is not a JSON object (a
 * SQL store reads text that does not parse as null) becomes `{ name }` and
 * `readable` is false: the client reports the job and shows it as failing,
 * without evaluating it. `tags` is kept only when it is a list of strings.
 * Every other field is kept as stored.
 */
export function readStoredJob(stored: StoredJob): { job: StoredJob; readable: boolean } {
  const definition: unknown = stored.definition;
  if (typeof definition !== "object" || definition === null || Array.isArray(definition)) {
    return { job: { ...stored, definition: { name: stored.name } }, readable: false };
  }
  const read = { ...(definition as StoredJobDefinition) };
  if ("tags" in read && !(Array.isArray(read.tags) && read.tags.every((tag) => typeof tag === "string"))) delete read.tags;
  return { job: { ...stored, definition: read }, readable: true };
}
