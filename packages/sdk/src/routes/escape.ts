/** Escapes text for HTML, attribute values included. Every string a page shows goes through this. */
export function escapeHtml(value: unknown): string {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

/**
 * Escapes a job name shown as text, with a line break allowed after each run
 * of `_`, `:`, `.`, `/` or `-`, so a long hook or class name wraps at its
 * separators rather than mid-word. Only for text: never an attribute, a URL
 * or a title.
 */
export function escapeName(value: unknown): string {
  return escapeHtml(value).replace(/([_:./-]+)(?=[^_:./-])/g, "$1<wbr>");
}
