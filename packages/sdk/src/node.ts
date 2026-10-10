/**
 * @cronwatch/sdk/node: serve a fetch-style handler (cw.routes().handler, or
 * a job's handler()) from Node's http module and the frameworks built on it:
 * a plain http server, Express and Connect, NestJS, Koa, Strapi, and Firebase
 * onRequest. The SDK core stays free of node: imports so it runs on Workers;
 * this entry point is the only one that uses Node's http and stream types.
 */
import type { IncomingMessage, ServerResponse } from "node:http";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import type { ReadableStream as NodeReadableStream } from "node:stream/web";

/** A fetch-style handler: a Request in, a Response out. */
export type FetchLike = (request: Request) => Response | Promise<Response>;

export interface NodeHandlerOptions {
  /**
   * Build the request URL from X-Forwarded-Proto and X-Forwarded-Host (the
   * first value of each) when present, instead of the connection's scheme and
   * the Host header. Only behind a proxy that sets or overwrites both, since
   * a client can send them too. Default false.
   */
  trustProxy?: boolean;
  /**
   * Answer only requests at this path or under it, and pass the rest on: to
   * `next()` as Express or Connect middleware, to the next Koa middleware,
   * and with a 404 when there is no next. The path is read from
   * `req.originalUrl` (so Express mount paths count) or `req.url`. Leave it
   * out to answer every request the handler is given, which suits
   * `app.use("/cronwatch", ...)`, a Nest controller, and a Firebase function.
   */
  basePath?: string;
}

/** Called by Express and Connect for the next middleware, or with an error. */
export type NodeNext = (error?: unknown) => void;

/** A handler for http.createServer, Express or Connect, Nest, and Firebase onRequest. */
export type NodeHandler = (req: IncomingMessage, res: ServerResponse, next?: NodeNext) => Promise<void>;

/** The parts of a Koa context the middleware uses, so the SDK needs no Koa types. */
export interface KoaContextLike {
  req: IncomingMessage;
  res: ServerResponse;
  respond?: boolean;
  /** Koa's own copy of the URL, kept when koa-mount rewrites req.url. */
  originalUrl?: string;
  /** Set by koa-bodyparser and similar, when they run before this middleware. */
  request?: { body?: unknown; rawBody?: unknown };
}

/** Where a request body may already be, when a parser has read the stream. */
export interface BodySource {
  /** The request target to use instead of req.originalUrl or req.url. */
  url?: string;
  /** The body's bytes as read (Firebase, Nest with rawBody: true, koa-bodyparser). */
  rawBody?: unknown;
  /** A body a parser has decoded (express.json, express.urlencoded). */
  body?: unknown;
}

type NodeRequest = IncomingMessage & { originalUrl?: string; rawBody?: unknown; body?: unknown };

function header(value: string | string[] | undefined): string | undefined {
  return Array.isArray(value) ? value[0] : value;
}

function firstValue(value: string | string[] | undefined): string | undefined {
  const first = header(value)?.split(",")[0]?.trim();
  return first ? first : undefined;
}

/** An origin from a scheme and host, or null when the host is not a bare host[:port]. */
function originFrom(proto: string, host: string): string | null {
  try {
    const url = new URL(`${proto}://${host}`);
    if (url.pathname !== "/" || url.username || url.password || url.search || url.hash) return null;
    return url.origin;
  } catch {
    return null;
  }
}

/** The path and query of a request target, which may be absolute-form. */
function pathAndQuery(target: string): string {
  if (/^[a-z][a-z0-9+.-]*:\/\//i.test(target)) {
    try {
      const url = new URL(target);
      return url.pathname + url.search;
    } catch {
      return "/";
    }
  }
  // "//x" must stay a path, not become a host, so it is never parsed relative to a base.
  return target.startsWith("/") ? target : `/${target}`;
}

function requestOrigin(req: IncomingMessage, trustProxy: boolean): string {
  const socket = req.socket as { encrypted?: boolean } | undefined;
  let proto = socket?.encrypted === true ? "https" : "http";
  let host = header(req.headers.host) ?? header(req.headers[":authority"] as string | string[] | undefined);
  if (trustProxy) {
    const fp = firstValue(req.headers["x-forwarded-proto"])?.toLowerCase();
    if (fp === "http" || fp === "https") proto = fp;
    const fh = firstValue(req.headers["x-forwarded-host"]);
    if (fh && originFrom(proto, fh) !== null) host = fh;
  }
  return (host ? originFrom(proto, host) : null) ?? `${proto}://localhost`;
}

/** The stream has not been read by a body parser, so it can be passed on as is. */
function unread(req: IncomingMessage): boolean {
  if (typeof req.on !== "function" || req.readable === false) return false;
  return !req.readableEnded && req.readableDidRead !== true;
}

/**
 * A body a parser decoded, encoded again for its content type: JSON as JSON,
 * a urlencoded form as a form. Anything else (multipart, unknown types) is
 * dropped, because it cannot be rebuilt faithfully.
 */
function reencode(parsed: unknown, headers: Headers): string | Uint8Array | null {
  if (parsed === undefined || parsed === null) return null;
  if (typeof parsed === "string" || parsed instanceof Uint8Array) return parsed;
  if (typeof parsed !== "object") return null;
  const type = (headers.get("content-type") ?? "").toLowerCase();
  let text: string | null = null;
  if (type.includes("application/x-www-form-urlencoded")) {
    const form = new URLSearchParams();
    for (const [key, value] of Object.entries(parsed)) {
      for (const v of Array.isArray(value) ? value : [value]) {
        if (v !== undefined && v !== null) form.append(key, typeof v === "object" ? JSON.stringify(v) : String(v));
      }
    }
    text = form.toString();
  } else if (type.includes("json")) {
    text = JSON.stringify(parsed);
  }
  if (text === null) return null;
  headers.delete("content-length");
  headers.delete("transfer-encoding");
  return text;
}

/**
 * A fetch Request for a Node request. The URL is the Host header (or the
 * forwarded host and scheme with trustProxy) plus req.originalUrl or req.url.
 * The body, for anything but GET and HEAD, is the first of: `rawBody` (from
 * the source, or req.rawBody), the request stream when nothing has read it,
 * or a body a parser decoded (req.body), re-encoded as JSON or a urlencoded
 * form to match its content type.
 */
export function toRequest(req: IncomingMessage, options: { trustProxy?: boolean; signal?: AbortSignal } = {}, source: BodySource = {}): Request {
  const node = req as NodeRequest;
  const target = source.url ?? node.originalUrl ?? req.url ?? "/";
  const url = requestOrigin(req, options.trustProxy === true) + pathAndQuery(target);

  const headers = new Headers();
  for (const [name, value] of Object.entries(req.headers)) {
    // HTTP/2 pseudo-headers (":authority") are not valid header names.
    if (value === undefined || name.startsWith(":")) continue;
    if (Array.isArray(value)) for (const v of value) headers.append(name, v);
    else headers.set(name, value);
  }

  const method = (req.method ?? "GET").toUpperCase();
  const init: RequestInit & { duplex?: "half" } = { method, headers };
  if (options.signal) init.signal = options.signal;
  if (method !== "GET" && method !== "HEAD") {
    const raw = source.rawBody ?? node.rawBody;
    // A Buffer is a Uint8Array view, which fetch reads with its offset.
    if (raw instanceof Uint8Array) init.body = raw as unknown as BodyInit;
    else if (typeof raw === "string") init.body = raw;
    else if (unread(req)) {
      init.body = Readable.toWeb(req) as unknown as ReadableStream<Uint8Array>;
      init.duplex = "half";
    } else {
      const body = reencode(source.body !== undefined ? source.body : node.body, headers);
      if (body !== null) init.body = body as unknown as BodyInit;
      else {
        // The bytes are gone, so the Request has no body and says so.
        headers.delete("content-length");
        headers.delete("transfer-encoding");
      }
    }
  }
  return new Request(url, init);
}

/**
 * Writes a fetch Response to a Node response: the status, every header
 * (each Set-Cookie as its own header line), and the body, streamed. A HEAD
 * request gets the headers only.
 */
export async function writeResponse(res: ServerResponse, response: Response, method = "GET"): Promise<void> {
  res.statusCode = response.status;
  response.headers.forEach((value, name) => {
    if (name !== "set-cookie") res.setHeader(name, value);
  });
  const cookies = response.headers.getSetCookie();
  if (cookies.length > 0) res.setHeader("set-cookie", cookies);
  if (response.body === null || method.toUpperCase() === "HEAD") {
    if (response.body !== null) await response.body.cancel().catch(() => {});
    res.end();
    return;
  }
  try {
    await pipeline(Readable.fromWeb(response.body as unknown as NodeReadableStream<Uint8Array>), res);
  } catch {
    // The client went away mid-body; there is no one left to tell.
  }
}

function mountOf(basePath: string | undefined): string | null {
  return basePath === undefined ? null : basePath.replace(/\/+$/, "");
}

function inMount(pathname: string, mount: string | null): boolean {
  return mount === null || mount === "" || pathname === mount || pathname.startsWith(`${mount}/`);
}

function pathnameOf(target: string): string {
  const path = pathAndQuery(target);
  const q = path.search(/[?#]/);
  return q === -1 ? path : path.slice(0, q);
}

/** Aborts the Request's signal when the client disconnects before the response is done. */
function disconnectSignal(res: ServerResponse): AbortSignal {
  const controller = new AbortController();
  res.once("close", () => {
    if (!res.writableFinished) controller.abort();
  });
  return controller.signal;
}

/**
 * A Node handler for a fetch-style handler. Use it as a plain server
 * (`http.createServer(toNodeHandler(routes.handler))`), as Express or Connect
 * middleware (`app.use("/cronwatch", toNodeHandler(routes.handler))`), from a
 * Nest controller, or as a Firebase `onRequest` function.
 *
 * With `basePath`, requests outside it go to `next()` (or get a 404 when
 * there is no next); without it, every request is answered. An error thrown
 * by the fetch handler goes to `next(error)` when there is a next, and is
 * otherwise answered with a plain 500.
 */
export function toNodeHandler(handler: FetchLike, options: NodeHandlerOptions = {}): NodeHandler {
  const mount = mountOf(options.basePath);
  const trustProxy = options.trustProxy === true;
  return async (req, res, next) => {
    const node = req as NodeRequest;
    if (!inMount(pathnameOf(node.originalUrl ?? req.url ?? "/"), mount)) {
      if (next) next();
      else {
        res.statusCode = 404;
        res.setHeader("content-type", "text/plain; charset=utf-8");
        res.end("Not found");
      }
      return;
    }
    try {
      const request = toRequest(req, { trustProxy, signal: disconnectSignal(res) });
      await writeResponse(res, await handler(request), request.method);
    } catch (error) {
      if (next) next(error);
      else if (!res.headersSent) {
        res.statusCode = 500;
        res.setHeader("content-type", "text/plain; charset=utf-8");
        res.end("Internal Server Error");
      } else res.destroy(error instanceof Error ? error : undefined);
    }
  };
}

/**
 * Koa middleware for a fetch-style handler. Requests outside `basePath` (when
 * given) go on to the next middleware. The rest are answered here with
 * `ctx.respond = false`, so Koa leaves the response alone. Place it before
 * any body parser; if one runs first, its `ctx.request.rawBody` or
 * `ctx.request.body` is used. An error thrown by the fetch handler is thrown
 * on to Koa before anything is written.
 */
export function toKoaMiddleware(handler: FetchLike, options: NodeHandlerOptions = {}): (ctx: KoaContextLike, next: () => Promise<unknown>) => Promise<void> {
  const mount = mountOf(options.basePath);
  const trustProxy = options.trustProxy === true;
  return async (ctx, next) => {
    const target = ctx.originalUrl ?? ctx.req.url ?? "/";
    if (!inMount(pathnameOf(target), mount)) {
      await next();
      return;
    }
    const request = toRequest(ctx.req, { trustProxy, signal: disconnectSignal(ctx.res) }, {
      url: target,
      rawBody: ctx.request?.rawBody,
      body: ctx.request?.body,
    });
    const response = await handler(request);
    ctx.respond = false;
    await writeResponse(ctx.res, response, request.method);
  };
}
