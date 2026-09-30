/**
 * The cronwatch.dev contact form service. nginx hands it POST /contact; it
 * checks the form and sends one email through Amazon SES (API v2
 * SendEmail, signed with AWS Signature Version 4), then redirects the
 * browser to /contact/sent/ or /contact/error/. No dependencies: Node's
 * http, crypto and fetch only.
 *
 *   node deploy/contact/server.mjs
 *
 * Environment (see deploy/README.md; the values live in an env file on the
 * server, never in the repository):
 *
 *   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY   an IAM user allowed only ses:SendEmail
 *   AWS_SESSION_TOKEN                          optional, for temporary credentials
 *   AWS_REGION                                 the SES region, default us-east-1
 *   CONTACT_FROM                               a verified sender, "CronWatch <contact@example.com>"
 *   CONTACT_TO                                 where messages go
 *   CONTACT_PORT                               default 3790; it listens on 127.0.0.1 only
 *   CONTACT_SES_URL                            tests only: a local endpoint in place of SES
 */
import { createHash, createHmac } from "node:crypto";
import { createServer } from "node:http";
import { realpathSync } from "node:fs";
import { pathToFileURL } from "node:url";

export const MAX_BODY = 16 * 1024;
export const MIN_FILL_MS = 3000;
const SENT = "/contact/sent/";
const FAILED = "/contact/error/";

/* ---- AWS Signature Version 4 ---- */

const sha256 = (data) => createHash("sha256").update(data, "utf8").digest("hex");
const hmac = (key, data) => createHmac("sha256", key).update(data, "utf8").digest();
const uriEncode = (text) => encodeURIComponent(text).replace(/[!'()*]/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`);

/**
 * Returns the headers to send: the given ones plus x-amz-date, the session
 * token when there is one, and authorization. Host is signed but not
 * returned, because fetch sets it. The same algorithm as
 * packages/sdk/src/alerts/sigv4.ts, on node:crypto.
 */
export function signV4({ method, url, headers, body, region, service, now }, { accessKeyId, secretAccessKey, sessionToken }) {
  const u = new URL(url);
  const amzDate = new Date(now).toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
  const day = amzDate.slice(0, 8);
  const out = {};
  for (const [name, value] of Object.entries(headers)) out[name.toLowerCase()] = value;
  out["x-amz-date"] = amzDate;
  if (sessionToken) out["x-amz-security-token"] = sessionToken;

  const signed = { ...out, host: u.host };
  const names = Object.keys(signed).sort();
  const pairs = [];
  u.searchParams.forEach((value, name) => pairs.push([uriEncode(name), uriEncode(value)]));
  pairs.sort(([a, av], [b, bv]) => (a < b ? -1 : a > b ? 1 : av < bv ? -1 : av > bv ? 1 : 0));
  const canonicalRequest = [
    method.toUpperCase(),
    u.pathname ? u.pathname.split("/").map(uriEncode).join("/") : "/",
    pairs.map(([n, v]) => `${n}=${v}`).join("&"),
    names.map((n) => `${n}:${String(signed[n]).trim().replace(/\s+/g, " ")}\n`).join(""),
    names.join(";"),
    sha256(body),
  ].join("\n");
  const scope = `${day}/${region}/${service}/aws4_request`;
  const stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, sha256(canonicalRequest)].join("\n");
  let key = hmac(`AWS4${secretAccessKey}`, day);
  key = hmac(key, region);
  key = hmac(key, service);
  key = hmac(key, "aws4_request");
  const signature = createHmac("sha256", key).update(stringToSign, "utf8").digest("hex");
  out.authorization = `AWS4-HMAC-SHA256 Credential=${accessKeyId}/${scope}, SignedHeaders=${names.join(";")}, Signature=${signature}`;
  return out;
}

/* ---- The form ---- */

/** Anything that could end or split a header line. */
const BREAKS = /[\r\n\u0085\u2028\u2029]/;
const CONTROL = /[\u0000-\u001f\u007f\u0085\u2028\u2029]+/g;
/** Makes text safe to place in a header: control characters (CR and LF among them) become a space. */
export const headerSafe = (s) => String(s).replace(CONTROL, " ").replace(/\s+/g, " ").trim();
/** A plain, sane address: one @, a dot in the domain, no spaces, quotes, brackets or line breaks. */
const EMAIL = /^[^\s@"<>()[\]\\,;:]{1,64}@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+$/;

/**
 * Checks a submitted form. Returns { ok: true, name, email, message } or
 * { ok: false, reason, drop } where drop means a bot: answer as if sent.
 */
export function checkForm(fields) {
  const get = (k) => (typeof fields.get(k) === "string" ? fields.get(k) : "");
  if (get("website") !== "") return { ok: false, reason: "honeypot", drop: true };
  const t = get("t");
  if (t !== "") {
    if (!/^\d{1,12}$/.test(t)) return { ok: false, reason: "bad-timer" };
    if (Number(t) < MIN_FILL_MS) return { ok: false, reason: "too-fast" };
  }
  // The name goes on the body's "Name:" line and into the subject, so it is
  // made one line: control characters and line breaks become spaces, and a
  // sender cannot add lines that pass for the service's own Email or IP.
  const name = headerSafe(get("name"));
  const email = get("email").trim();
  const message = get("message").replace(/\r\n?/g, "\n").trim();
  if (name.length < 1 || name.length > 200) return { ok: false, reason: "bad-name" };
  if (email.length > 320 || BREAKS.test(email) || !EMAIL.test(email)) return { ok: false, reason: "bad-email" };
  if (message.length < 1 || message.length > 5000) return { ok: false, reason: "bad-message" };
  return { ok: true, name, email, message };
}

/** The caller's address: nginx's X-Real-IP when it looks like one, else the socket's. */
function clientIp(req) {
  const real = req.headers["x-real-ip"];
  if (typeof real === "string" && /^[0-9A-Fa-f:.]{2,45}$/.test(real)) return real;
  return req.socket.remoteAddress ?? "unknown";
}

/* ---- Rate limits ---- */

/**
 * Who a limit counts a post against: an IPv4 address as it is, and an IPv6
 * address by its /64, since one host is commonly handed a whole /64 and
 * could otherwise take a new address for every post. An IPv4-mapped IPv6
 * address counts as its IPv4 address. Anything unparsable counts as itself.
 */
export function sourceKey(ip) {
  const text = String(ip).replace(/%.*$/, "").toLowerCase();
  if (!text.includes(":")) return text;
  const mapped = /^::ffff:(\d{1,3}(?:\.\d{1,3}){3})$/.exec(text);
  if (mapped) return mapped[1];
  let body = text;
  // A trailing dotted quad is the last two groups.
  const quad = /^(.*:)(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(body);
  if (quad) {
    const [, head, a, b, c, d] = quad;
    if ([a, b, c, d].some((n) => Number(n) > 255)) return text;
    body = `${head}${((Number(a) << 8) | Number(b)).toString(16)}:${((Number(c) << 8) | Number(d)).toString(16)}`;
  }
  const halves = body.split("::");
  if (halves.length > 2) return text;
  const part = (s) => (s === "" ? [] : s.split(":"));
  const head = part(halves[0]);
  const tail = halves.length === 2 ? part(halves[1]) : [];
  const missing = 8 - head.length - tail.length;
  if (halves.length === 2 ? missing < 1 : missing !== 0) return text;
  const groups = [...head, ...Array(missing).fill("0"), ...tail];
  if (!groups.every((g) => /^[0-9a-f]{1,4}$/.test(g))) return text;
  return `${groups.slice(0, 4).map((g) => parseInt(g, 16).toString(16)).join(":")}::/64`;
}

/**
 * How many messages may go before the service stops sending: per source (an
 * IPv4 address or an IPv6 /64), and in all, so that many sources together
 * cannot use up the SES sending quota and crowd out real messages. nginx
 * limits posts per address as well; these count only posts that would send.
 */
export const LIMITS = {
  perSource: { limit: 10, windowMs: 60 * 60_000 },
  hourly: { limit: 30, windowMs: 60 * 60_000 },
  daily: { limit: 100, windowMs: 24 * 60 * 60_000 },
};

/** Sliding-window counters. take(source, now) counts a send and returns null, or the reason it may not go. */
export function createLimiter(limits = LIMITS) {
  const bySource = new Map();
  const all = [];
  const recent = (times, now, windowMs) => {
    while (times.length > 0 && times[0] <= now - windowMs) times.shift();
    return times.length;
  };
  return {
    take(source, now) {
      const longest = Math.max(limits.hourly.windowMs, limits.daily.windowMs);
      recent(all, now, longest);
      const inWindow = (windowMs) => all.filter((t) => t > now - windowMs).length;
      if (inWindow(limits.daily.windowMs) >= limits.daily.limit || inWindow(limits.hourly.windowMs) >= limits.hourly.limit) return "over-cap";
      // Forget sources whose posts are all old, so the map stays small.
      if (bySource.size > 10_000) for (const [k, times] of bySource) if (recent(times, now, limits.perSource.windowMs) === 0) bySource.delete(k);
      const times = bySource.get(source) ?? [];
      if (recent(times, now, limits.perSource.windowMs) >= limits.perSource.limit) return "rate-limited";
      times.push(now);
      bySource.set(source, times);
      all.push(now);
      return null;
    },
  };
}

/* ---- The service ---- */

/** Reads and checks the configuration. Throws with the names of what is missing, never the values. */
export function readConfig(env) {
  const missing = ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "CONTACT_FROM", "CONTACT_TO"].filter((k) => !env[k]?.trim());
  if (missing.length) throw new Error(`missing required environment variable${missing.length === 1 ? "" : "s"}: ${missing.join(", ")} (see deploy/README.md)`);
  const region = (env.AWS_REGION || "us-east-1").trim();
  if (!/^[a-z0-9-]+$/.test(region)) throw new Error("AWS_REGION should look like us-east-1");
  for (const k of ["CONTACT_FROM", "CONTACT_TO"]) if (BREAKS.test(env[k].trim())) throw new Error(`${k} must be one line`);
  const port = Number(env.CONTACT_PORT ?? 3790);
  if (!Number.isInteger(port) || port < 0 || port > 65535) throw new Error("CONTACT_PORT should be a port number");
  let sesUrl = `https://email.${region}.amazonaws.com/v2/email/outbound-emails`;
  if (env.CONTACT_SES_URL) {
    // For tests only, so it may only point at this machine.
    if (!/^http:\/\/(127\.0\.0\.1|localhost)(:\d+)?\//.test(env.CONTACT_SES_URL)) throw new Error("CONTACT_SES_URL may only point at 127.0.0.1 or localhost (it is for tests)");
    sesUrl = env.CONTACT_SES_URL;
  }
  return {
    region, port, sesUrl,
    from: env.CONTACT_FROM.trim(),
    to: env.CONTACT_TO.trim(),
    credentials: { accessKeyId: env.AWS_ACCESS_KEY_ID.trim(), secretAccessKey: env.AWS_SECRET_ACCESS_KEY.trim(), sessionToken: env.AWS_SESSION_TOKEN?.trim() || undefined },
  };
}

/** Sends one message through SES. Resolves to null when sent, or a short reason safe to log. */
async function sendEmail(config, { name, email, message, ip, userAgent, at }) {
  const text = [
    `Name: ${name}`,
    `Email: ${email}`,
    `Time: ${at}`,
    `IP: ${ip}`,
    `User agent: ${userAgent}`,
    "",
    message,
    "",
    "Sent from the contact form on cronwatch.dev. Reply to answer.",
  ].join("\n");
  const body = JSON.stringify({
    FromEmailAddress: config.from,
    Destination: { ToAddresses: [config.to] },
    ReplyToAddresses: [email],
    Content: {
      Simple: {
        Subject: { Data: headerSafe(`cronwatch.dev contact: ${name}`).slice(0, 200), Charset: "UTF-8" },
        Body: { Text: { Data: text, Charset: "UTF-8" } },
      },
    },
    EmailTags: [{ Name: "source", Value: "cronwatch-contact" }],
  });
  const headers = signV4({ method: "POST", url: config.sesUrl, headers: { "content-type": "application/json" }, body, region: config.region, service: "ses", now: Date.now() }, config.credentials);
  try {
    const res = await fetch(config.sesUrl, { method: "POST", headers, body, signal: AbortSignal.timeout(10_000) });
    if (res.ok) return null;
    // AWS names the error in x-amzn-ErrorType; the body could echo request details, so it is not logged.
    const type = (res.headers.get("x-amzn-errortype") ?? "").split(":")[0].replace(/[^A-Za-z0-9]/g, "").slice(0, 60);
    await res.body?.cancel();
    return `ses-${res.status}${type ? `-${type}` : ""}`;
  } catch (e) {
    return e?.name === "TimeoutError" ? "ses-timeout" : "ses-unreachable";
  }
}

/**
 * The HTTP server. `log` gets one line per submission: time, outcome,
 * reason and address, never the message, the sender's details or any credential.
 */
export function createContactServer(config, { log = (line) => console.log(line), limits = LIMITS, now = () => Date.now() } = {}) {
  const limiter = createLimiter(limits);
  const record = (ip, outcome, reason) => log(JSON.stringify({ time: new Date().toISOString(), outcome, ...(reason ? { reason } : {}), ip }));
  return createServer((req, res) => {
    const finish = (status, location, extra = {}) => {
      res.writeHead(status, { "cache-control": "no-store", "content-type": "text/plain; charset=utf-8", ...(location ? { location } : {}), ...extra });
      res.end(location ? `See ${location}\n` : `${status}\n`);
    };
    const path = (req.url ?? "").split("?")[0];
    if (path !== "/contact") return finish(404);
    if (req.method !== "POST") return finish(405, null, { allow: "POST" });
    const type = String(req.headers["content-type"] ?? "").split(";")[0].trim().toLowerCase();
    if (type !== "application/x-www-form-urlencoded") return finish(415);

    const ip = clientIp(req);
    // The rest of an oversized body is read and thrown away, so the client
    // gets the redirect rather than a reset connection.
    const tooBig = () => {
      record(ip, "rejected", "too-large");
      finish(303, FAILED, { connection: "close" });
    };
    if (Number(req.headers["content-length"] ?? 0) > MAX_BODY) return tooBig();
    const chunks = [];
    let size = 0, over = false;
    req.on("data", (chunk) => {
      if (over) return;
      size += chunk.length;
      if (size > MAX_BODY) { over = true; tooBig(); return; }
      chunks.push(chunk);
    });
    req.on("error", () => {});
    req.on("end", async () => {
      if (over) return;
      const fields = new URLSearchParams(Buffer.concat(chunks).toString("utf8"));
      const form = checkForm(fields);
      if (!form.ok) {
        record(ip, form.drop ? "dropped" : "rejected", form.reason);
        return finish(303, form.drop ? SENT : FAILED);
      }
      const limited = limiter.take(sourceKey(ip), now());
      if (limited) {
        record(ip, "rejected", limited);
        return finish(303, FAILED);
      }
      const userAgent = headerSafe(req.headers["user-agent"] ?? "").slice(0, 400) || "none";
      const failure = await sendEmail(config, { ...form, ip, userAgent, at: new Date().toISOString() });
      record(ip, failure ? "failed" : "sent", failure);
      finish(303, failure ? FAILED : SENT);
    });
  });
}

/* ---- Run ---- */

// The unit starts this through the /var/www/cronwatch.dev symlink, and Node
// reports import.meta.url with symlinks resolved, so compare real paths.
if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) {
  let config;
  try {
    config = readConfig(process.env);
  } catch (e) {
    console.error(`cronwatch-contact: ${e.message}`);
    process.exit(1);
  }
  const server = createContactServer(config);
  server.requestTimeout = 15_000;
  server.headersTimeout = 10_000;
  server.listen(config.port, "127.0.0.1", () => {
    console.log(`cronwatch-contact: listening on 127.0.0.1:${server.address().port}, sending to SES in ${config.region}`);
  });
  const stop = () => server.close(() => process.exit(0));
  process.on("SIGTERM", stop);
  process.on("SIGINT", stop);
}
