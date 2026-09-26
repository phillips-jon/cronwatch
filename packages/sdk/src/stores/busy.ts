/** How long opening SQLite keeps retrying a busy database before it gives up. */
export const BUSY_RETRY_MS = 2_000;

function sleepSync(ms: number): void {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

/**
 * Runs `fn`, retrying while SQLite answers SQLITE_BUSY (or SQLITE_LOCKED),
 * with a short growing pause, for up to `budgetMs` in all. Opening a
 * better-sqlite3 database is synchronous, so the pause is too.
 */
export function retryBusy<T>(fn: () => T, budgetMs = BUSY_RETRY_MS, sleep: (ms: number) => void = sleepSync): T {
  let waited = 0;
  for (let attempt = 0; ; attempt++) {
    try {
      return fn();
    } catch (e) {
      const code = (e as { code?: unknown } | null)?.code;
      const busy = typeof code === "string" && (code.startsWith("SQLITE_BUSY") || code.startsWith("SQLITE_LOCKED"));
      if (!busy || waited >= budgetMs) throw e;
      const pause = Math.min(10 * 2 ** attempt, 200, budgetMs - waited);
      sleep(pause);
      waited += pause;
    }
  }
}
