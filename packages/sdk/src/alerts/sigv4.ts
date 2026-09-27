/**
 * AWS Signature Version 4 with Web Crypto, for the SES channel.
 * Spec: https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv-create-signed-request.html
 * Checked against the AWS SigV4 test suite (test/sigv4.test.ts).
 */
import { hex, sha256Hex } from "./shared.js";

export interface SigV4Credentials {
  accessKeyId: string;
  secretAccessKey: string;
  /** For temporary credentials (STS, an IAM role). Sent and signed as X-Amz-Security-Token. */
  sessionToken?: string;
}

export interface SigV4Request {
  method: string;
  url: string;
  /** Headers to send and sign. Host is taken from the URL, and X-Amz-Date from `now`. */
  headers: Record<string, string>;
  body: string;
  region: string;
  service: string;
  /** Epoch milliseconds. */
  now: number;
}

/**
 * Returns the headers to send: the given ones plus x-amz-date, the session
 * token when there is one, and authorization. Host is signed but not
 * returned, because fetch sets it.
 */
export async function signV4(request: SigV4Request, credentials: SigV4Credentials): Promise<Record<string, string>> {
  const url = new URL(request.url);
  const amzDate = new Date(request.now).toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
  const day = amzDate.slice(0, 8);
  const headers: Record<string, string> = {};
  for (const [name, value] of Object.entries(request.headers)) headers[name.toLowerCase()] = value;
  headers["x-amz-date"] = amzDate;
  if (credentials.sessionToken) headers["x-amz-security-token"] = credentials.sessionToken;

  const signed: Record<string, string> = { ...headers, host: url.host };
  const names = Object.keys(signed).sort();
  const canonicalHeaders = names.map((n) => `${n}:${signed[n]!.trim().replace(/\s+/g, " ")}\n`).join("");
  const signedHeaders = names.join(";");
  const canonicalRequest = [
    request.method.toUpperCase(),
    canonicalUri(url.pathname),
    canonicalQuery(url.searchParams),
    canonicalHeaders,
    signedHeaders,
    await sha256Hex(request.body),
  ].join("\n");
  const scope = `${day}/${request.region}/${request.service}/aws4_request`;
  const stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, await sha256Hex(canonicalRequest)].join("\n");

  let key = await hmac(new TextEncoder().encode(`AWS4${credentials.secretAccessKey}`), day);
  key = await hmac(key, request.region);
  key = await hmac(key, request.service);
  key = await hmac(key, "aws4_request");
  const signature = hex(await hmac(key, stringToSign));

  headers.authorization = `AWS4-HMAC-SHA256 Credential=${credentials.accessKeyId}/${scope}, SignedHeaders=${signedHeaders}, Signature=${signature}`;
  return headers;
}

async function hmac(key: Uint8Array, data: string): Promise<Uint8Array> {
  const cryptoKey = await crypto.subtle.importKey("raw", key as Uint8Array<ArrayBuffer>, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", cryptoKey, new TextEncoder().encode(data)));
}

/** RFC 3986 encoding of every byte but the unreserved characters. */
function uriEncode(text: string): string {
  return encodeURIComponent(text).replace(/[!'()*]/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`);
}

function canonicalUri(path: string): string {
  if (!path) return "/";
  // URL.pathname is already encoded once; every AWS service but S3 expects each segment encoded again.
  return path.split("/").map(uriEncode).join("/");
}

function canonicalQuery(params: URLSearchParams): string {
  const pairs: [string, string][] = [];
  params.forEach((value, name) => pairs.push([uriEncode(name), uriEncode(value)]));
  pairs.sort(([a, av], [b, bv]) => (a < b ? -1 : a > b ? 1 : av < bv ? -1 : av > bv ? 1 : 0));
  return pairs.map(([n, v]) => `${n}=${v}`).join("&");
}
