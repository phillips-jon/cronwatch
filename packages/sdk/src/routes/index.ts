import type { CronWatch } from "../client.js";
import { isDevelopment, readEnv } from "../env.js";
import { constantTimeEqual, json } from "../http.js";
import { parseDuration } from "../duration.js";
import type { Duration, Run } from "../types.js";
import { dashboardPage, jobPage, messagePage } from "./html.js";

export interface RoutesOptions {
  /**
   * Required to reach anything. Send it as `Authorization: Bearer <token>`,
   * or open the dashboard once with `?token=<token>` and a cookie is set.
   * Defaults to process.env.CRONWATCH_TOKEN (on Cloudflare Workers, which
   * have no process, pass env.CRONWATCH_TOKEN); an empty string counts as unset.
   * With no token while NODE_ENV is "development" or "test", the routes make
   * a random one and print a sign-in link to the server log on their first
   * request; with no token otherwise they answer 503. Pass `null` to opt out
   * and serve them open everywhere, for example behind your own auth.
   *
   * The check endpoint (/api/check) also accepts the client's cronSecret, so
   * a platform cron that sends `Authorization: Bearer <CRON_SECRET>` can
   * trigger checks without knowing the dashboard token.
   */
  token?: string | null;
  /** Where the routes are mounted, so links resolve. Default "/cronwatch". */
  basePath?: string;
}

export type FetchHandler = (request: Request) => Promise<Response>;

export interface Routes {
  handler: FetchHandler;
  GET: FetchHandler;
  POST: FetchHandler;
  DELETE: FetchHandler;
}

const COOKIE = "cronwatch_token";

/**
 * The cookie holds a digest of the token, so a leaked cookie does not reveal
 * the bearer token itself: the SHA-256 of "cronwatch-cookie:<token>", as hex.
 * Web Crypto, so the routes need nothing from node: and run on Workers too.
 */
async function cookieValue(token: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`cronwatch-cookie:${token}`));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

const DEFAULT_RUNS = 20;
const MAX_RUNS = 500;

const CSP = "default-src 'none'; style-src 'unsafe-inline'; img-src 'self' data:; form-action 'self'; frame-ancestors 'none'; base-uri 'none'";
// same-origin rather than no-referrer: under no-referrer browsers send
// `Origin: null` on form posts, which the CSRF check would refuse, and the
// forms redirect back to the page named by the same-origin Referer.
const SECURITY_HEADERS = { "x-content-type-options": "nosniff", "referrer-policy": "same-origin", "x-robots-tag": "noindex" };

/**
 * A token for one routes instance in development, when none is configured:
 * 32 random bytes, base64url (43 characters).
 */
function developmentToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/**
 * The line a development token is announced with, printed once with
 * console.info on the routes' first request:
 *
 *   [cronwatch] CRONWATCH_TOKEN is not set, so this development server made a token for the dashboard. Sign in: <origin><base>/?token=<token>
 *
 * <origin> is the first request's URL origin (scheme, host and any port),
 * <base> the base path without a trailing slash ("" when mounted at the
 * root), and <token> the token as generated (base64url, so nothing needs
 * escaping).
 */
function developmentSignInLine(origin: string, base: string, token: string): string {
  return `[cronwatch] CRONWATCH_TOKEN is not set, so this development server made a token for the dashboard. Sign in: ${origin}${base}/?token=${token}`;
}

function safeDecode(value: string): string | null {
  try {
    return decodeURIComponent(value);
  } catch {
    return null;
  }
}

function readCookie(request: Request, name: string): string | null {
  const header = request.headers.get("cookie");
  if (!header) return null;
  for (const part of header.split(";")) {
    const [k, ...rest] = part.trim().split("=");
    // A malformed escape counts as no cookie.
    if (k === name) return safeDecode(rest.join("="));
  }
  return null;
}

function stripBase(pathname: string, base: string): string {
  let path = pathname.startsWith(base) ? pathname.slice(base.length) : pathname;
  if (path === "") path = "/";
  if (path.length > 1 && path.endsWith("/")) path = path.slice(0, -1);
  return path;
}

async function readBody(request: Request): Promise<Record<string, string>> {
  const type = request.headers.get("content-type") ?? "";
  try {
    if (type.includes("application/json")) {
      const data = await request.json();
      return typeof data === "object" && data !== null ? Object.fromEntries(Object.entries(data).map(([k, v]) => [k, String(v)])) : {};
    }
    if (type.includes("application/x-www-form-urlencoded") || type.includes("multipart/form-data")) {
      const form = await request.formData();
      const out: Record<string, string> = {};
      for (const [k, v] of form.entries()) out[k] = String(v);
      return out;
    }
  } catch {
    return {};
  }
  return {};
}

/**
 * A browser attaches Origin or Sec-Fetch-Site to a cross-site form post, and
 * a page cannot forge either. Non-browser clients send neither.
 */
function crossSite(request: Request, url: URL): boolean {
  const origin = request.headers.get("origin");
  if (origin !== null && origin !== url.origin) return true;
  const site = request.headers.get("sec-fetch-site");
  return site !== null && site !== "same-origin" && site !== "none";
}

/** Absent means one hour; a number or numeric string is milliseconds. Throws on anything else. */
function silenceDuration(value: string | null | undefined): Duration {
  if (value === undefined || value === null) return "1h";
  const text = value.trim();
  const duration: Duration = /^\d+(\.\d+)?$/.test(text) ? Number(text) : text;
  parseDuration(duration, "silence duration");
  return duration;
}

function runsLimit(value: string | null): number {
  const n = value === null || value.trim() === "" ? NaN : Math.trunc(Number(value));
  return Number.isFinite(n) ? Math.min(MAX_RUNS, Math.max(1, n)) : DEFAULT_RUNS;
}

/**
 * A fetch-style handler serving the dashboard and a small JSON API. Mount it
 * in a Next.js app at app/cronwatch/[[...path]]/route.ts:
 *
 *   export const { GET, POST, DELETE } = cw.routes();
 */
export function createRoutes(cw: CronWatch, options: RoutesOptions = {}): Routes {
  const optedOut = options.token === null;
  const configured = optedOut ? null : (options.token || readEnv("CRONWATCH_TOKEN") || null);
  const base = (options.basePath ?? "/cronwatch").replace(/\/+$/, "");
  const developing = isDevelopment();
  // A fetch handler cannot tell a local caller from a remote one (proxies,
  // tunnels and `next dev` listening on every interface all look alike), so
  // development gets a token too: made here, and shown only in the server log.
  const generated = !configured && !optedOut && developing;
  const token = generated ? developmentToken() : configured;
  let announced = false;
  // Worked out on the first request that needs it, then kept.
  let cookie: Promise<string> | null = null;
  const expectedCookie = (value: string) => (cookie ??= cookieValue(value));

  const serve = async (request: Request, url: URL, path: string, wantsHtml: boolean): Promise<Response> => {
    const method = request.method.toUpperCase();

    if (generated && !announced) {
      announced = true;
      console.info(developmentSignInLine(url.origin, base, token!));
    }

    // No token outside development: fail closed.
    if (!token && !optedOut) {
      return wantsHtml
        ? html(messagePage("CronWatch routes are locked", "Set CRONWATCH_TOKEN (or pass token to cw.routes()), or pass token: null to serve them open behind your own auth.", base), 503)
        : api({ ok: false, error: "CRONWATCH_TOKEN is not set" }, 503);
    }

    if (method !== "GET" && method !== "HEAD" && crossSite(request, url)) {
      return wantsHtml
        ? html(messagePage("Cross-site request refused", "Changes can only be made from the dashboard itself.", base), 403)
        : api({ ok: false, error: "Cross-site request refused" }, 403);
    }

    const bearer = request.headers.get("authorization")?.replace(/^Bearer\s+/i, "") ?? null;
    if (token) {
      // ?token= is only the sign-in that moves the token into a cookie.
      const query = wantsHtml && method === "GET" ? url.searchParams.get("token") : null;
      const sent = readCookie(request, COOKIE);
      const isCheck = path === "/api/check";
      const cronSecretOk = isCheck && bearer !== null && cw.cronSecret !== null && constantTimeEqual(bearer, cw.cronSecret);
      const tokenOk =
        bearer !== null ? constantTimeEqual(bearer, token)
        : query !== null ? constantTimeEqual(query, token)
        : sent !== null && constantTimeEqual(sent, await expectedCookie(token));
      if (!cronSecretOk && !tokenOk) {
        if (generated) {
          return wantsHtml
            ? html(messagePage("Sign in", "CRONWATCH_TOKEN is not set, so this development server made a token. The sign-in link is in the server log: open it once and this browser stays signed in.", base), 401)
            : api({ ok: false, error: "Unauthorized: CRONWATCH_TOKEN is not set, so this development server made a token; it is in the server log" }, 401);
        }
        return wantsHtml
          ? html(messagePage("Sign in", `Open this page with ?token=<your CRONWATCH_TOKEN> once and it will stay signed in.`, base), 401)
          : api({ ok: false, error: "Unauthorized" }, 401);
      }
      if (query !== null) {
        // Move the token from the URL into a cookie so it is not in history or logs.
        url.searchParams.delete("token");
        const secure = url.protocol === "https:" ? "; Secure" : "";
        return redirect(url.pathname + (url.search || ""), {
          "set-cookie": `${COOKIE}=${await expectedCookie(token)}; Path=${base || "/"}; HttpOnly; SameSite=Lax; Max-Age=${60 * 60 * 24 * 30}${secure}`,
        });
      }
    }

    const redirectBack = () => {
      const referer = request.headers.get("referer") ?? "";
      return redirect(referer.startsWith(url.origin + "/") ? referer : `${base}/`);
    };
    const decoded = path.split("/").filter(Boolean).map(safeDecode);
    if (decoded.some((part) => part === null)) {
      return wantsHtml ? html(messagePage("Bad request", "The path is not valid.", base), 400) : api({ ok: false, error: "Bad path" }, 400);
    }
    const parts = decoded as string[];

    // HTML
    if (method === "GET" && path === "/") {
      const entries = await cw.jobsWithRuns(20);
      const runsByJob = new Map<string, Run[]>(entries.map((entry) => [entry.job.name, entry.runs]));
      return html(dashboardPage(entries.map((entry) => entry.job), runsByJob, cw.now(), base, null));
    }
    if (method === "GET" && parts[0] === "jobs" && parts.length === 2) {
      const job = await cw.jobSummary(parts[1]!);
      if (!job) return html(messagePage("No such job", `${parts[1]} is not in the store.`, base), 404);
      return html(jobPage(job, await cw.runs(job.name, 50), cw.now(), base));
    }
    if (method === "POST" && path === "/check") {
      await cw.check();
      return redirectBack();
    }
    if (method === "POST" && parts[0] === "jobs" && parts.length === 3) {
      const name = parts[1]!;
      if (parts[2] === "forget") {
        await cw.forget(name);
        return redirect(`${base}/`);
      }
      if (parts[2] !== "silence" && parts[2] !== "unsilence") return html(messagePage("Not found", path, base), 404);
      if (!(await cw.jobSummary(name))) return html(messagePage("No such job", `${name} is not in the store.`, base), 404);
      if (parts[2] === "silence") {
        let duration: Duration;
        try {
          duration = silenceDuration((await readBody(request)).for);
        } catch (e) {
          return html(messagePage("Not silenced", (e as Error).message, base), 400);
        }
        await cw.silence(name, duration);
      } else await cw.unsilence(name);
      return redirectBack();
    }

    // JSON API
    if (parts[0] === "api") {
      const rest = parts.slice(1);
      if (method === "GET" && rest[0] === "jobs" && rest.length === 1) {
        return api({ ok: true, jobs: await cw.jobs() });
      }
      if (rest[0] === "jobs" && rest.length === 2) {
        const name = rest[1]!;
        if (method === "GET") {
          const job = await cw.jobSummary(name);
          if (!job) return api({ ok: false, error: "No such job" }, 404);
          return api({ ok: true, job, runs: await cw.runs(name, runsLimit(url.searchParams.get("runs"))) });
        }
        if (method === "DELETE") {
          if (!(await cw.jobSummary(name))) return api({ ok: false, error: "No such job" }, 404);
          await cw.forget(name);
          return api({ ok: true });
        }
      }
      if (method === "POST" && rest[0] === "jobs" && rest.length === 3) {
        const name = rest[1]!;
        if (!(await cw.jobSummary(name))) return api({ ok: false, error: "No such job" }, 404);
        if (rest[2] === "silence") {
          const body = await readBody(request);
          let duration: Duration;
          try {
            duration = silenceDuration(body.for ?? url.searchParams.get("for"));
          } catch (e) {
            return api({ ok: false, error: (e as Error).message }, 400);
          }
          return api({ ok: true, state: await cw.silence(name, duration) });
        }
        if (rest[2] === "unsilence") return api({ ok: true, state: await cw.unsilence(name) });
      }
      if (rest[0] === "check" && rest.length === 1) {
        // A page cannot send an Authorization header cross-site, so a GET
        // may only run the check when it carries a bearer (token or cron secret).
        if (method === "GET" && bearer === null) {
          return api({ ok: false, error: "Use POST, or GET with an Authorization bearer" }, 405, { allow: "POST" });
        }
        if (method === "GET" || method === "POST") {
          const result = await cw.check();
          return api({ ok: true, ...result });
        }
      }
      if (method === "GET" && rest[0] === "runs" && rest.length === 2) {
        const run = await cw.getRun(rest[1]!);
        return run ? api({ ok: true, run }) : api({ ok: false, error: "No such run" }, 404);
      }
      return api({ ok: false, error: "Not found" }, 404);
    }

    return html(messagePage("Not found", path, base), 404);
  };

  const handler: FetchHandler = async (request) => {
    let wantsHtml = true;
    try {
      const url = new URL(request.url);
      const path = stripBase(url.pathname, base);
      wantsHtml = !path.startsWith("/api");
      return await serve(request, url, path, wantsHtml);
    } catch (e) {
      try {
        cw.onError(e, "routes");
      } catch {
        // An onError that throws must not turn a 500 into an unhandled rejection.
      }
      return wantsHtml
        ? html(messagePage("Something went wrong", "The request failed and the error was reported.", base), 500)
        : api({ ok: false, error: "Internal error" }, 500);
    }
  };

  return { handler, GET: handler, POST: handler, DELETE: handler };
}

function api(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return json(body, status, { ...SECURITY_HEADERS, ...headers });
}

function redirect(location: string, headers: Record<string, string> = {}): Response {
  return new Response(null, { status: 303, headers: { location, "cache-control": "no-store", ...SECURITY_HEADERS, ...headers } });
}

function html(body: string, status = 200): Response {
  return new Response(body, {
    status,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
      "content-security-policy": CSP,
      "x-frame-options": "DENY",
      ...SECURITY_HEADERS,
    },
  });
}
