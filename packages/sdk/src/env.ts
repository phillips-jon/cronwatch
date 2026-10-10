/**
 * Environment variables, read only where there is a `process` to read them
 * from. Cloudflare Workers without nodejs_compat have none: there every value
 * comes from the options, which is where a Worker passes its env bindings.
 */
export function readEnv(name: string): string | undefined {
  return typeof process === "undefined" || !process.env ? undefined : process.env[name];
}

/**
 * A secret from the environment (CRONWATCH_TOKEN, CRON_SECRET): undefined
 * when the variable is unset, empty, or only whitespace (as
 * String.prototype.trim sees it), so a blank value counts as not set and the
 * routes and handlers fail closed. Any other value is used as it is, untrimmed.
 */
export function readSecretEnv(name: string): string | undefined {
  const value = readEnv(name);
  return value === undefined || value.trim() === "" ? undefined : value;
}

/**
 * A token or secret passed in code: a string, null (the opt-out), or
 * undefined (not given). A string that is empty or only whitespace counts as
 * not given. Anything else (false, a number, an object) throws a TypeError
 * naming the option, so it never becomes a password.
 */
export function secretOption(value: unknown, what: string): string | null | undefined {
  if (value === undefined || value === null) return value;
  if (typeof value !== "string") {
    throw new TypeError(`${what} must be a string, or null to opt out, not ${Array.isArray(value) ? "an array" : typeof value}`);
  }
  return value.trim() === "" ? undefined : value;
}

/**
 * The environment's name, as every CronWatch library reads it: the first of
 * CRONWATCH_ENV, APP_ENV, and NODE_ENV that holds more than spaces, trimmed
 * and lowercased, with "prod" read as "production" and "dev", "local",
 * "test", and "testing" as "development"; "" when none is set, which is not
 * development. The variables are written out in full so that bundlers which
 * inline process.env.NODE_ENV still can.
 */
export function environment(): string {
  if (typeof process === "undefined" || !process.env) return "";
  for (const value of [process.env.CRONWATCH_ENV, process.env.APP_ENV, process.env.NODE_ENV]) {
    const name = typeof value === "string" ? value.trim().toLowerCase() : "";
    if (name === "") continue;
    if (name === "prod") return "production";
    if (name === "dev" || name === "local" || name === "test" || name === "testing") return "development";
    return name;
  }
  return "";
}

/** Development makes a dashboard token of its own and lets a handler with no secret run. */
export function isDevelopment(): boolean {
  return environment() === "development";
}

/** Production warns that the default in-memory store forgets on restart. */
export function isProduction(): boolean {
  return environment() === "production";
}
