/**
 * Environment variables, read only where there is a `process` to read them
 * from. Cloudflare Workers without nodejs_compat have none: there every value
 * comes from the options, which is where a Worker passes its env bindings.
 */
export function readEnv(name: string): string | undefined {
  return typeof process === "undefined" || !process.env ? undefined : process.env[name];
}

/** NODE_ENV is "development" or "test". Written out in full so bundlers that inline process.env.NODE_ENV still can. */
export function isDevelopment(): boolean {
  if (typeof process === "undefined" || !process.env) return false;
  const mode = process.env.NODE_ENV;
  return mode === "development" || mode === "test";
}
