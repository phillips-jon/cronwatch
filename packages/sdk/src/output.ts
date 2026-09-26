/** Output is capped so a chatty job cannot fill the store. The tail is kept. */
export const OUTPUT_CAP = 16 * 1024;

export function capOutput(text: string): string {
  if (text.length <= OUTPUT_CAP) return text;
  return "[earlier output trimmed]\n" + text.slice(text.length - OUTPUT_CAP);
}

/** "Name: message" and the first five stack frames. */
export function errorMessage(error: unknown): string {
  if (error instanceof Error) {
    // The stack repeats the header (over several lines when the message has
    // newlines), so take only its frames.
    const frames = (error.stack ?? "").split("\n").filter((line) => /^\s+at /.test(line)).slice(0, 5);
    return `${error.name}: ${error.message}${frames.length ? `\n${frames.join("\n")}` : ""}`;
  }
  if (typeof error === "string") return error;
  try {
    return JSON.stringify(error);
  } catch {
    return String(error);
  }
}
