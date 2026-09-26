/** Output is capped so a chatty job cannot fill the store. The tail is kept. */
export const OUTPUT_CAP = 16 * 1024;

export function capOutput(text: string): string {
  if (text.length <= OUTPUT_CAP) return text;
  return "[earlier output trimmed]\n" + text.slice(text.length - OUTPUT_CAP);
}

export function errorMessage(error: unknown): string {
  if (error instanceof Error) {
    const stack = error.stack ? `\n${error.stack.split("\n").slice(1, 6).join("\n")}` : "";
    return `${error.name}: ${error.message}${stack}`;
  }
  if (typeof error === "string") return error;
  try {
    return JSON.stringify(error);
  } catch {
    return String(error);
  }
}
