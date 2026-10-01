import type { Cronwatch } from "../client.js";
import { isDevelopment, readEnv } from "../env.js";
import { constantTimeEqual, json } from "../http.js";
import { parseDuration } from "../duration.js";
import type { Duration, JobSummary, Run } from "../types.js";
import { dashboardPage, jobPage, messagePage } from "./html.js";
import { staticAsset, type StaticAsset } from "./pwa.js";
import { API_VERSION, VERSION } from "../version.js";
import { BOARD_BEHIND_MS, BOARD_LANES, BOARD_RUNS, weekRunsLimit, type LaneInput } from "./timeline.js";

export interface RoutesOptions {
  /**
   * Required to reach anything. Send it as `Authorization: Bearer <token>`,
   * or open the dashboard once with `?token=<token>` and a cookie is set.
   * Defaults to process.env.CRONWATCH_TOKEN (on Cloudflare Workers, which
   * have no process, pass env.CRONWATCH_TOKEN); an empty string counts as unset.
   * With no token in development (the first of CRONWATCH_ENV, APP_ENV and
   * NODE_ENV that is set names "development", "dev", "local", "test" or
   * "testing"), the routes make a random one and print a sign-in link to the
   * server log on their first request; with no token otherwise they answer
   * 503. Pass `null` to opt out
   * and serve them open everywhere, for example behind your own auth.
   *
   * The check endpoint (/api/check) also accepts the client's cronSecret, so
   * a platform cron that sends `Authorization: Bearer <CRON_SECRET>` can
   * trigger checks without knowing the dashboard token.
   */
  token?: string | null;
  /** Where the routes are mounted, so links resolve. Default "/cronwatch". */
  basePath?: string;
  /**
   * The public origin the dashboard is served from, such as
   * "https://app.example.com", for an app behind a proxy whose request URLs
   * carry an internal host or scheme. Used in place of the request URL's
   * origin for the cross-site check on writes, the sign-in redirect (its
   * cookie is Secure when this is https, and the redirect back after a form
   * follows a Referer on this origin) and the development sign-in line.
   * Takes precedence over trustProxy. Without it, the development sign-in
   * line shows the request's origin only when its host is loopback
   * (localhost, *.localhost, 127.0.0.0/8 or ::1), and otherwise leaves the
   * host out, since a client controls it.
   */
  origin?: string;
  /**
   * Take the public origin from X-Forwarded-Proto and X-Forwarded-Host (the
   * first value of each, falling back to the request URL's scheme or host
   * for whichever is missing) when a request carries either. Only for an app
   * whose proxy sets or overwrites both headers: a client can send them too.
   * Default false, which ignores them.
   */
  trustProxy?: boolean;
}

export type FetchHandler = (request: Request) => Promise<Response>;

export interface Routes {
  handler: FetchHandler;
  GET: FetchHandler;
  POST: FetchHandler;
  DELETE: FetchHandler;
}

const COOKIE = "cronwatch_token";
/** The package GET <base>/api names: each port answers with its own. */
const LIBRARY = "@cronwatch/sdk";

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
/** Runs per job the board reads in one go: the table's sparkline, and most jobs' lanes. */
const BOARD_PAGE_RUNS = 20;

/**
 * The board's timeline lanes, the first BOARD_LANES jobs. The runs already
 * read for the table usually cover the last day; only a job whose twenty
 * newest runs all fall inside it (one that runs more often than every hour or so) is
 * read again, deeper, and those reads go out together.
 */
async function boardLanes(cw: Cronwatch, entries: { job: JobSummary; runs: Run[] }[], now: number): Promise<LaneInput[]> {
  const from = now - BOARD_BEHIND_MS;
  return Promise.all(entries.slice(0, BOARD_LANES).map(async ({ job, runs }) => {
    const short = runs.length >= BOARD_PAGE_RUNS && runs[runs.length - 1]!.startedAt > from;
    if (!short) return { job, runs, complete: true };
    const deeper = await cw.runs(job.name, BOARD_RUNS);
    return { job, runs: deeper, complete: deeper.length < BOARD_RUNS };
  }));
}

// 'self' only for what the app shell needs: app.js (which registers the
// service worker and nothing else), the manifest, the worker and the icons.
// No inline script, and the pages work without any.
const CSP = "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; img-src 'self' data:; manifest-src 'self'; worker-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'";
/** For the SVG icons, should one be opened on its own. */
const ASSET_CSP = "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'";
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
 * <origin> is the `origin` option when set. Otherwise it is the first
 * request's public origin (scheme, host and any port: the forwarded one
 * under trustProxy, else the request URL's), but only when its host is
 * loopback ("localhost", a name ending in ".localhost", 127.0.0.0/8 or
 * ::1). That host comes from the request, which a client controls, so for
 * any other host the line leaves it out, and a spoofed first request cannot
 * point the link, token and all, somewhere else:
 *
 *   [cronwatch] CRONWATCH_TOKEN is not set, so this development server made a token for the dashboard. Sign in: <base>/?token=<token> on this server (the first request's host is not local, so the link leaves it out)
 *
 * <base> is the base path without a trailing slash ("" when mounted at the
 * root), and <token> the token as generated (base64url, so nothing needs
 * escaping).
 */
function developmentSignInLine(origin: string | null, base: string, token: string): string {
  const intro = "[cronwatch] CRONWATCH_TOKEN is not set, so this development server made a token for the dashboard. Sign in: ";
  return origin === null
    ? `${intro}${base}/?token=${token} on this server (the first request's host is not local, so the link leaves it out)`
    : `${intro}${origin}${base}/?token=${token}`;
}

/**
 * Whether an origin's host is loopback: "localhost", a name ending in
 * ".localhost", an IPv4 address in 127.0.0.0/8, or the IPv6 address ::1.
 */
function isLoopbackOrigin(origin: string): boolean {
  let host: string;
  try {
    host = new URL(origin).hostname.toLowerCase();
  } catch {
    return false;
  }
  if (host === "localhost" || host.endsWith(".localhost")) return true;
  if (host === "[::1]") return true;
  const octets = /^127\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(host);
  return octets !== null && octets.slice(1).every((o) => Number(o) <= 255);
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

/** The first entry of a comma-separated header, trimmed, or null when there is none. */
function firstValue(value: string | null): string | null {
  const first = value?.split(",")[0]?.trim();
  return first ? first : null;
}

/**
 * The origin configured with `origin`, normalised, or null. Throws on a value
 * that is not an http or https origin, so a typo fails at startup.
 */
function configuredOrigin(value: string | undefined): string | null {
  if (value === undefined || value === "") return null;
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new Error(`routes: origin must be an absolute URL such as "https://app.example.com", got ${JSON.stringify(value)}`);
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") throw new Error(`routes: origin must be http or https, got ${JSON.stringify(value)}`);
  return url.origin;
}

/**
 * The origin a browser sees for this request, with trustProxy: the forwarded
 * scheme and host when present and well formed, otherwise the request URL's own.
 */
function forwardedOrigin(request: Request, url: URL): string {
  const proto = firstValue(request.headers.get("x-forwarded-proto"))?.toLowerCase() ?? null;
  const host = firstValue(request.headers.get("x-forwarded-host"));
  if (proto === null && host === null) return url.origin;
  if (proto !== null && proto !== "http" && proto !== "https") return url.origin;
  try {
    const built = new URL(`${proto ?? url.protocol.slice(0, -1)}://${host ?? url.host}`);
    // A "host" carrying a path, credentials, a query or a fragment is not a host.
    if (built.pathname !== "/" || built.username || built.password || built.search || built.hash) return url.origin;
    return built.origin;
  } catch {
    return url.origin;
  }
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
function crossSite(request: Request, publicOrigin: string): boolean {
  const origin = request.headers.get("origin");
  if (origin !== null && origin !== publicOrigin) return true;
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
 * The dashboard and its JSON API for a client.
 * @deprecated Use `cw.routes(options)`, the one way to mount the dashboard
 * in every port. This name still works through 1.x and goes in 2.0.
 */
export function createRoutes(cw: Cronwatch, options: RoutesOptions = {}): Routes {
  return cw.routes(options);
}

/**
 * A fetch-style handler serving the dashboard and a small JSON API, which
 * cw.routes() returns. Mount it in a Next.js app at
 * app/cronwatch/[[...path]]/route.ts:
 *
 *   export const { GET, POST, DELETE } = cw.routes();
 */
export function buildRoutes(cw: Cronwatch, options: RoutesOptions = {}): Routes {
  const optedOut = options.token === null;
  const configured = optedOut ? null : (options.token || readEnv("CRONWATCH_TOKEN") || null);
  const base = (options.basePath ?? "/cronwatch").replace(/\/+$/, "");
  const developing = isDevelopment();
  const fixedOrigin = configuredOrigin(options.origin);
  const trustProxy = options.trustProxy === true;
  const originOf = (request: Request, url: URL): string =>
    fixedOrigin ?? (trustProxy ? forwardedOrigin(request, url) : url.origin);
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
    const publicOrigin = originOf(request, url);

    if (generated && !announced) {
      announced = true;
      const shown = fixedOrigin ?? (isLoopbackOrigin(publicOrigin) ? publicOrigin : null);
      console.info(developmentSignInLine(shown, base, token!));
    }

    // The app shell: the manifest, icons, service worker, app.js and the
    // offline page. Served to anyone, since a browser fetches some of it
    // without cookies and none of it says anything about the jobs.
    if (method === "GET" || method === "HEAD") {
      if (path === "/offline") {
        return html(messagePage("You are offline", "CronWatch shows live data from your app, so it needs a connection.", base), 200, "no-cache");
      }
      const asset = staticAsset(path, base);
      if (asset) return shell(asset, base);
    }

    // No token outside development: fail closed.
    if (!token && !optedOut) {
      return wantsHtml
        ? html(messagePage("CronWatch routes are locked", "Set CRONWATCH_TOKEN (or pass token to cw.routes()), or pass token: null to serve them open behind your own auth.", base), 503)
        : api({ ok: false, error: "CRONWATCH_TOKEN is not set" }, 503);
    }

    if (method !== "GET" && method !== "HEAD" && crossSite(request, publicOrigin)) {
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
            ? html(messagePage("Sign in", "CRONWATCH_TOKEN is not set, so this development server made a token. The sign-in link is in the server log: open it once and this browser stays signed in.", base, true), 401)
            : api({ ok: false, error: "Unauthorized: CRONWATCH_TOKEN is not set, so this development server made a token; it is in the server log" }, 401);
        }
        return wantsHtml
          ? html(messagePage("Sign in", `Open this page with ?token=<your CRONWATCH_TOKEN> once and it will stay signed in.`, base, true), 401)
          : api({ ok: false, error: "Unauthorized" }, 401);
      }
      if (query !== null) {
        // Move the token from the URL into a cookie so it is not in history or logs.
        url.searchParams.delete("token");
        const secure = publicOrigin.startsWith("https:") ? "; Secure" : "";
        return redirect(url.pathname + (url.search || ""), {
          "set-cookie": `${COOKIE}=${await expectedCookie(token)}; Path=${base || "/"}; HttpOnly; SameSite=Lax; Max-Age=${60 * 60 * 24 * 30}${secure}`,
        });
      }
    }

    const redirectBack = () => {
      const referer = request.headers.get("referer") ?? "";
      return redirect(referer.startsWith(publicOrigin + "/") ? referer : `${base}/`);
    };
    const decoded = path.split("/").filter(Boolean).map(safeDecode);
    if (decoded.some((part) => part === null)) {
      return wantsHtml ? html(messagePage("Bad request", "The path is not valid.", base), 400) : api({ ok: false, error: "Bad path" }, 400);
    }
    const parts = decoded as string[];

    // HTML
    if (method === "GET" && path === "/") {
      const entries = await cw.jobsWithRuns(BOARD_PAGE_RUNS);
      const now = cw.now();
      const runsByJob = new Map<string, Run[]>(entries.map((entry) => [entry.job.name, entry.runs]));
      return html(dashboardPage(entries.map((entry) => entry.job), runsByJob, now, base, null, await boardLanes(cw, entries, now)));
    }
    if (method === "GET" && parts[0] === "jobs" && parts.length === 2) {
      const job = await cw.jobSummary(parts[1]!);
      if (!job) return html(messagePage("No such job", `${parts[1]} is not in the store.`, base), 404);
      const now = cw.now();
      // Enough runs to draw the job's week; the page lists the newest fifty.
      const limit = weekRunsLimit(job, now);
      const runs = await cw.runs(job.name, limit);
      return html(jobPage(job, runs, now, base, runs.length < limit));
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
      // What is serving the API, so a client such as @cronwatch/mcp can tell.
      if (method === "GET" && rest.length === 0) {
        return api({ ok: true, library: LIBRARY, version: VERSION, api: API_VERSION });
      }
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
          await cw.silence(name, duration);
          return api({ ok: true, job: await cw.jobSummary(name) });
        }
        if (rest[2] === "unsilence") {
          await cw.unsilence(name);
          return api({ ok: true, job: await cw.jobSummary(name) });
        }
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

/**
 * An app shell file. The worker may be scoped to the base (it is served from
 * there anyway); the SVGs get a CSP of their own.
 */
function shell(asset: StaticAsset, base: string): Response {
  const headers: Record<string, string> = { "content-type": asset.type, "cache-control": asset.cache, ...SECURITY_HEADERS };
  if (asset.type === "image/svg+xml") headers["content-security-policy"] = ASSET_CSP;
  if (asset.worker) headers["service-worker-allowed"] = `${base}/`;
  return new Response(asset.body, { status: 200, headers });
}

function html(body: string, status = 200, cache = "no-store"): Response {
  return new Response(body, {
    status,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": cache,
      "content-security-policy": CSP,
      "x-frame-options": "DENY",
      ...SECURITY_HEADERS,
    },
  });
}
