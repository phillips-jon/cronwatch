/** Output is capped so a chatty job cannot fill the store. The tail is kept. */
export const OUTPUT_CAP = 16 * 1024;

/**
 * NUL characters are removed first, since Postgres refuses them in TEXT and
 * JSONB and the whole run row would be lost. The cap then applies to what is
 * left.
 */
export function capOutput(text: string): string {
  const clean = stripNul(text);
  if (clean.length <= OUTPUT_CAP) return clean;
  return TRIMMED + clean.slice(clean.length - OUTPUT_CAP);
}

const TRIMMED = "[earlier output trimmed]\n";

/**
 * How much text before the kept tail redaction reads, and never keeps: three
 * times the longest secret a default pattern can match (a PEM key's 16 KB body
 * with its header and footer, under OUTPUT_CAP + 1024), since a replacement
 * grows what it replaces at most threefold.
 */
export const REDACT_EDGE = 3 * (OUTPUT_CAP + 1024);

/**
 * Output or an error as it is stored: redacted, then capped like capOutput,
 * so the cut cannot fall inside a secret and keep what follows its label.
 * Text of at most OUTPUT_CAP + REDACT_EDGE is redacted whole. Longer text is
 * cut to that many units from its end first, and after redacting, the first
 * REDACT_EDGE units are never kept: a secret whose label fell before that cut
 * is left out with them. NULs go before and after `redact`.
 */
export function redactAndCap(text: string, redact: (text: string) => string): string {
  const clean = stripNul(text);
  const from = clean.length - (OUTPUT_CAP + REDACT_EDGE);
  if (from <= 0) return capOutput(redact(clean));
  const redacted = stripNul(redact(clean.slice(from)));
  return TRIMMED + redacted.slice(Math.max(redacted.length - OUTPUT_CAP, REDACT_EDGE));
}

/** Removes every U+0000. */
export function stripNul(text: string): string {
  return text.includes("\u0000") ? text.replace(/\u0000/g, "") : text;
}

/**
 * Removes every U+0000 from JSON text, keys and strings alike, by dropping
 * each \u0000 escape (a NUL can appear in JSON no other way). Escapes are
 * read left to right in pairs, so an escaped backslash followed by "u0000"
 * is left as it is.
 */
export function stripJsonNul(json: string): string {
  return json.includes("\\u0000") ? json.replace(/\\(u0000|[\s\S])/g, (escape, next: string) => (next === "u0000" ? "" : escape)) : json;
}

/** "Name: message" and the first five stack frames, capped like output. */
export function errorMessage(error: unknown): string {
  return capOutput(describeError(error));
}

/** "Name: message" and the first five stack frames, not capped: see redactAndCap. */
export function describeError(error: unknown): string {
  if (error instanceof Error) {
    // The stack repeats the header (over several lines when the message has
    // newlines), so take only its frames.
    const frames = (error.stack ?? "").split("\n").filter((line) => /^\s+at /.test(line)).slice(0, 5);
    return `${error.name}: ${error.message}${frames.length ? `\n${frames.join("\n")}` : ""}`;
  }
  if (typeof error === "string") return error;
  try {
    return JSON.stringify(error) ?? String(error);
  } catch {
    return String(error);
  }
}

const REDACTED = "[redacted]";

// Bounded quantifiers throughout, so a long line cannot make these backtrack.
// They apply in this order, each to the text the ones before it left.
const SECRET_PATTERNS: [RegExp, string | ((match: string, ...groups: string[]) => string)][] = [
  // A PEM private key, header to footer. Without a footer (the output was
  // trimmed) it runs to the end of the base64 body. A "-" that starts five
  // dashes ends the body, so the footer is never swallowed into it.
  [
    /-----BEGIN (?:[A-Z0-9]{1,20} ){0,3}PRIVATE KEY-----(?:[A-Za-z0-9+/=\s,:]|-(?!----)){0,16384}(?:-----END (?:[A-Z0-9]{1,20} ){0,3}PRIVATE KEY-----)?/g,
    REDACTED,
  ],
  // password=..., API_KEY: ..., "client_secret": "...", TOKEN='...', token=...,
  // :password=>"..." (but not max_tokens: 800). A quoted value is blanked to
  // its closing quote, spaces and all, and keeps its quotes.
  [
    /\b([A-Za-z0-9_-]{0,40}(?:secret|token|passw(?:or)?d|pwd|api[_-]?key|access[_-]?key|private[_-]?key|credential)[A-Za-z0-9_-]{0,40}(?<![Tt][Oo][Kk][Ee][Nn][Ss])"?\s{0,3}(?:=>|[=:])\s{0,3})(?:(")[^"\n]{1,4096}"|(')[^'\n]{1,4096}'|["']?[^\s"',;&]{1,4096})/gi,
    (_match, name: string, double?: string, single?: string) => {
      const quote = double ?? single ?? "";
      return `${name}${quote}${REDACTED}${quote}`;
    },
  ],
  // Authorization: Basic <base64> and Authorization: Token <token>, also as a JSON or hash entry.
  [/\b((?:proxy-)?authorization["']?\s{0,3}(?:=>|[=:])\s{0,3}["']?\s{0,3}(?:basic|token)\s{1,3})[A-Za-z0-9._~+/=:-]{1,4096}/gi, `$1${REDACTED}`],
  // Credentials inside a URL: postgres://user:password@host. The password
  // runs to the last "@" before a "/" or a space, so one that contains "@"
  // is blanked whole.
  [/(\b[a-z][a-z0-9+.-]{0,30}:\/\/[^\s/:@]{0,256}:)[^\s/]{1,256}@/gi, `$1${REDACTED}@`],
  // Authorization: Bearer <token>
  [/\b(Bearer\s{1,3})[A-Za-z0-9._~+/=-]{8,4096}/g, `$1${REDACTED}`],
  // A bare JWT: three base64url segments, the first starting eyJ.
  [/\beyJ[A-Za-z0-9_-]{4,4096}\.[A-Za-z0-9_-]{4,4096}\.[A-Za-z0-9_-]{0,4096}/g, REDACTED],
  // Incoming webhook URLs carry their secret in the path.
  [/(\bhooks\.slack\.com\/(?:services|workflows|triggers)\/)[A-Za-z0-9/_-]{1,255}/gi, `$1${REDACTED}`],
  [/(\bdiscord(?:app)?\.com\/api\/(?:v\d{1,2}\/)?webhooks\/)[A-Za-z0-9/_-]{1,255}/gi, `$1${REDACTED}`],
  // Well-known token shapes: AWS, GitHub, Slack, Stripe, Anthropic, OpenAI, and Google style keys.
  [/\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/g, REDACTED],
  [/\b(?:gh[pousr]_[A-Za-z0-9]{30,255}|github_pat_[A-Za-z0-9_]{20,255})\b/g, REDACTED],
  [/\bxox[abposr]-[A-Za-z0-9-]{10,255}/g, REDACTED],
  [/\b[rsp]k_(?:live|test)_[A-Za-z0-9]{10,255}\b/g, REDACTED],
  [/\bwhsec_[A-Za-z0-9+/=]{16,255}/g, REDACTED],
  [/\bsk-[A-Za-z0-9_-]{20,255}/g, REDACTED],
  [/\bAIza[0-9A-Za-z_-]{35}(?![0-9A-Za-z_-])/g, REDACTED],
];

/**
 * The default `redact`: blanks values that look like secrets (key=value pairs
 * with secret-ish names, Authorization headers, URL credentials, bearer
 * tokens, JWTs, PEM private keys, webhook URLs, and well-known token formats)
 * before output or an error is stored, shown, or sent anywhere.
 */
export function redactSecrets(text: string): string {
  let out = text;
  for (const [pattern, replacement] of SECRET_PATTERNS) out = out.replace(pattern, replacement as string);
  return out;
}
