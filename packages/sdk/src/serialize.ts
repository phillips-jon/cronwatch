import type { JobDefinition, StoredJobDefinition } from "./types.js";

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
