/** Output is capped so a chatty job cannot fill the store. The tail is kept. */
export const OUTPUT_CAP = 16 * 1024;

export function capOutput(text: string): string {
  if (text.length <= OUTPUT_CAP) return text;
  return "[earlier output trimmed]\n" + text.slice(text.length - OUTPUT_CAP);
}

/** "Name: message" and the first five stack frames, capped like output. */
export function errorMessage(error: unknown): string {
  return capOutput(describeError(error));
}

function describeError(error: unknown): string {
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
const SECRET_PATTERNS: [RegExp, string | ((match: string, ...groups: string[]) => string)][] = [
  // password=..., API_KEY: ..., "client_secret": "...", TOKEN='...', token=... (but not max_tokens: 800).
  // A quoted value is blanked to its closing quote, spaces and all, and keeps its quotes.
  [
    /\b([A-Za-z0-9_-]{0,40}(?:secret|token|passw(?:or)?d|pwd|api[_-]?key|access[_-]?key|private[_-]?key|credential)[A-Za-z0-9_-]{0,40}(?<![Tt][Oo][Kk][Ee][Nn][Ss])"?\s{0,3}[=:]\s{0,3})(?:(")[^"\n]{1,4096}"|(')[^'\n]{1,4096}'|["']?[^\s"',;&]{1,4096})/gi,
    (_match, name: string, double?: string, single?: string) => {
      const quote = double ?? single ?? "";
      return `${name}${quote}${REDACTED}${quote}`;
    },
  ],
  // Credentials inside a URL: postgres://user:password@host
  [/(\b[a-z][a-z0-9+.-]{0,30}:\/\/[^\s/:@]{0,256}:)[^\s/@]{1,256}@/gi, `$1${REDACTED}@`],
  // Authorization: Bearer <token>
  [/\b(Bearer\s{1,3})[A-Za-z0-9._~+/=-]{8,4096}/g, `$1${REDACTED}`],
  // Well-known token shapes: AWS, GitHub, Slack, Stripe, Anthropic and OpenAI style keys.
  [/\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/g, REDACTED],
  [/\b(?:gh[pousr]_[A-Za-z0-9]{30,255}|github_pat_[A-Za-z0-9_]{20,255})\b/g, REDACTED],
  [/\bxox[abposr]-[A-Za-z0-9-]{10,255}/g, REDACTED],
  [/\b[rsp]k_(?:live|test)_[A-Za-z0-9]{10,255}\b/g, REDACTED],
  [/\bsk-[A-Za-z0-9_-]{20,255}/g, REDACTED],
];

/**
 * The default `redact`: blanks values that look like secrets (key=value pairs
 * with secret-ish names, URL credentials, bearer tokens and well-known token
 * formats) before output or an error is stored, shown or sent anywhere.
 */
export function redactSecrets(text: string): string {
  let out = text;
  for (const [pattern, replacement] of SECRET_PATTERNS) out = out.replace(pattern, replacement as string);
  return out;
}
