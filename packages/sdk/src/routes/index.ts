import type { CronWatch } from "../client.js";
import { json } from "../http.js";
import { parseDuration } from "../duration.js";
import type { Run } from "../types.js";
import { dashboardPage, jobPage, messagePage } from "./html.js";

export interface RoutesOptions {
  /**
   * Required to reach anything. Send it as `Authorization: Bearer <token>`,
   * or open the dashboard once with `?token=<token>` and a cookie is set.
   * Defaults to process.env.CRONWATCH_TOKEN. With no token at all, the routes
   * are open in development and refuse to serve in production.
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

function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function readCookie(request: Request, name: string): string | null {
  const header = request.headers.get("cookie");
  if (!header) return null;
  for (const part of header.split(";")) {
    const [k, ...rest] = part.trim().split("=");
    if (k === name) return decodeURIComponent(rest.join("="));
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
 * A fetch-style handler serving the dashboard and a small JSON API. Mount it
 * in a Next.js app at app/cronwatch/[[...path]]/route.ts:
 *
 *   export const { GET, POST, DELETE } = cw.routes();
 */
export function createRoutes(cw: CronWatch, options: RoutesOptions = {}): Routes {
  const token = options.token === undefined ? (process.env.CRONWATCH_TOKEN ?? null) : options.token;
  const base = (options.basePath ?? "/cronwatch").replace(/\/+$/, "");
  const production = process.env.NODE_ENV === "production";

  const handler: FetchHandler = async (request) => {
    const url = new URL(request.url);
    const path = stripBase(url.pathname, base);
    const wantsHtml = !path.startsWith("/api");
    const method = request.method.toUpperCase();

    if (!token && production) {
      return wantsHtml
        ? html(messagePage("CronWatch routes are locked", "Set CRONWATCH_TOKEN (or pass token to cw.routes()) to use them in production.", base), 503)
        : json({ ok: false, error: "CRONWATCH_TOKEN is not set" }, 503);
    }

    if (token) {
      const bearer = request.headers.get("authorization")?.replace(/^Bearer\s+/i, "") ?? null;
      const query = url.searchParams.get("token");
      const cookie = readCookie(request, COOKIE);
      const presented = bearer ?? query ?? cookie;
      const isCheck = path === "/api/check";
      const cronSecretOk = isCheck && bearer !== null && cw.cronSecret !== null && constantTimeEqual(bearer, cw.cronSecret);
      if (!cronSecretOk && (presented === null || !constantTimeEqual(presented, token))) {
        return wantsHtml
          ? html(messagePage("Sign in", `Open this page with ?token=<your CRONWATCH_TOKEN> once and it will stay signed in.`, base), 401)
          : json({ ok: false, error: "Unauthorized" }, 401);
      }
      if (query !== null && wantsHtml && method === "GET") {
        // Move the token from the URL into a cookie so it is not in history or logs.
        url.searchParams.delete("token");
        const secure = url.protocol === "https:" ? "; Secure" : "";
        return new Response(null, {
          status: 303,
          headers: {
            location: url.pathname + (url.search || ""),
            "set-cookie": `${COOKIE}=${encodeURIComponent(token)}; Path=${base || "/"}; HttpOnly; SameSite=Lax; Max-Age=${60 * 60 * 24 * 30}${secure}`,
          },
        });
      }
    }

    const redirectBack = () => {
      const referer = request.headers.get("referer") ?? "";
      const location = referer.startsWith(url.origin + "/") ? referer : `${base}/`;
      return new Response(null, { status: 303, headers: { location } });
    };
    const jobName = (segment: string | undefined) => (segment ? decodeURIComponent(segment) : "");
    const parts = path.split("/").filter(Boolean);

    // HTML
    if (method === "GET" && path === "/") {
      const jobs = await cw.jobs();
      const runsByJob = new Map<string, Run[]>();
      for (const job of jobs) runsByJob.set(job.name, await cw.runs(job.name, 20));
      return html(dashboardPage(jobs, runsByJob, cw.now(), base, null));
    }
    if (method === "GET" && parts[0] === "jobs" && parts.length === 2) {
      const job = await cw.jobSummary(jobName(parts[1]));
      if (!job) return html(messagePage("No such job", `${jobName(parts[1])} is not in the store.`, base), 404);
      return html(jobPage(job, await cw.runs(job.name, 50), cw.now(), base));
    }
    if (method === "POST" && path === "/check") {
      await cw.check();
      return redirectBack();
    }
    if (method === "POST" && parts[0] === "jobs" && parts.length === 3) {
      const name = jobName(parts[1]);
      const body = await readBody(request);
      if (parts[2] === "silence") await cw.silence(name, safeDuration(body.for, "1h"));
      else if (parts[2] === "unsilence") await cw.unsilence(name);
      else if (parts[2] === "forget") {
        await cw.forget(name);
        return new Response(null, { status: 303, headers: { location: `${base}/` } });
      } else return html(messagePage("Not found", path, base), 404);
      return redirectBack();
    }

    // JSON API
    if (parts[0] === "api") {
      const rest = parts.slice(1);
      if (method === "GET" && rest[0] === "jobs" && rest.length === 1) {
        return json({ ok: true, jobs: await cw.jobs() });
      }
      if (rest[0] === "jobs" && rest.length === 2) {
        const name = jobName(rest[1]);
        if (method === "GET") {
          const job = await cw.jobSummary(name);
          if (!job) return json({ ok: false, error: "No such job" }, 404);
          const limit = Number(url.searchParams.get("runs") ?? 20);
          return json({ ok: true, job, runs: await cw.runs(name, Number.isFinite(limit) ? limit : 20) });
        }
        if (method === "DELETE") {
          await cw.forget(name);
          return json({ ok: true });
        }
      }
      if (method === "POST" && rest[0] === "jobs" && rest.length === 3) {
        const name = jobName(rest[1]);
        if (!(await cw.jobSummary(name))) return json({ ok: false, error: "No such job" }, 404);
        const body = await readBody(request);
        if (rest[2] === "silence") return json({ ok: true, state: await cw.silence(name, safeDuration(body.for ?? url.searchParams.get("for"), "1h")) });
        if (rest[2] === "unsilence") return json({ ok: true, state: await cw.unsilence(name) });
      }
      if ((method === "GET" || method === "POST") && rest[0] === "check" && rest.length === 1) {
        const result = await cw.check();
        return json({ ok: true, ...result });
      }
      if (method === "GET" && rest[0] === "runs" && rest.length === 2) {
        const run = await cw.getRun(rest[1]!);
        return run ? json({ ok: true, run }) : json({ ok: false, error: "No such run" }, 404);
      }
      return json({ ok: false, error: "Not found" }, 404);
    }

    return html(messagePage("Not found", path, base), 404);
  };

  return { handler, GET: handler, POST: handler, DELETE: handler };
}

function safeDuration(value: string | null | undefined, fallback: string): string {
  if (!value) return fallback;
  try {
    parseDuration(value);
    return value;
  } catch {
    return fallback;
  }
}

function html(body: string, status = 200): Response {
  return new Response(body, {
    status,
    headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store", "x-robots-tag": "noindex" },
  });
}
