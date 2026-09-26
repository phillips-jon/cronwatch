import { capOutput, OUTPUT_CAP } from "./output.js";
import type { Run } from "./types.js";

/** What a job function receives. */
export interface JobContext {
  readonly name: string;
  readonly runId: string;
  readonly startedAt: number;
  /** Aborts when the job's timeout elapses. Honour it if the work can stop. */
  readonly signal: AbortSignal;
  /** Append a line of output. Kept with the run, capped at 16 KB, shown in alerts and the dashboard. */
  log(...parts: unknown[]): void;
  /** Report a number for this run: tokens, cost, rows, anything. Watched against budgets and baselines. */
  metric(name: string, value: number): void;
  metrics(values: Record<string, number>): void;
}

export interface RunRecorder {
  context: JobContext;
  output(): string | null;
  /**
   * What an expect rule is checked against: everything logged, or when that
   * ran long, the first 16 KB and the last 16 KB. The stored output keeps only
   * the tail, so a "done" line printed early would otherwise be lost.
   */
  expectText(): string | null;
  metrics(): Record<string, number>;
  abort(): void;
}

function stringify(part: unknown): string {
  if (typeof part === "string") return part;
  if (part instanceof Error) return `${part.name}: ${part.message}`;
  try {
    return JSON.stringify(part);
  } catch {
    return String(part);
  }
}

export function createRecorder(run: Run): RunRecorder {
  const lines: string[] = [];
  let size = 0;
  const head: string[] = [];
  let headSize = 0;
  let dropped = false;
  const metrics: Record<string, number> = {};
  const controller = new AbortController();

  const context: JobContext = {
    name: run.job,
    runId: run.id,
    startedAt: run.startedAt,
    signal: controller.signal,
    log(...parts) {
      const line = parts.map(stringify).join(" ");
      if (headSize < OUTPUT_CAP) {
        head.push(line);
        headSize += line.length + 1;
      }
      lines.push(line);
      size += line.length + 1;
      // Drop from the front once well past the cap; capOutput trims exactly at the end.
      while (size > 64 * 1024 && lines.length > 1) {
        size -= lines.shift()!.length + 1;
        dropped = true;
      }
    },
    metric(name, value) {
      if (typeof value !== "number" || !Number.isFinite(value)) {
        throw new Error(`metric "${name}" must be a finite number`);
      }
      metrics[name] = value;
    },
    metrics(values) {
      for (const [k, v] of Object.entries(values)) context.metric(k, v);
    },
  };

  return {
    context,
    output: () => (lines.length === 0 ? null : capOutput(lines.join("\n"))),
    expectText: () => {
      if (lines.length === 0) return null;
      const all = lines.join("\n");
      if (!dropped && all.length <= 2 * OUTPUT_CAP) return all;
      return head.join("\n").slice(0, OUTPUT_CAP) + "\n" + all.slice(-OUTPUT_CAP);
    },
    metrics: () => ({ ...metrics }),
    abort: () => controller.abort(),
  };
}
