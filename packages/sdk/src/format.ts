import { formatDuration, formatRelative } from "./duration.js";
import type { AlertDraft, BudgetBreach } from "./evaluate.js";
import { formatNumber } from "./evaluate.js";
import type { Alert, StoredJobDefinition } from "./types.js";

function when(at: number | null | undefined, now: number): string {
  if (at === null || at === undefined) return "never";
  return `${new Date(at).toISOString().replace("T", " ").slice(0, 19)} UTC (${formatRelative(at, now)})`;
}

function firstLines(text: string | null, n: number): string {
  if (!text) return "";
  return text.split("\n").slice(0, n).join("\n");
}

function tail(text: string | null, n: number): string {
  if (!text) return "";
  const lines = text.trimEnd().split("\n");
  return lines.slice(Math.max(0, lines.length - n)).join("\n");
}

/** Turns a draft into the title and message every channel shows. */
export function composeAlert(draft: AlertDraft, def: StoredJobDefinition, now: number): Alert {
  const name = def.name;
  const run = draft.run;
  const d = draft.details;
  let title: string;
  const lines: string[] = [];

  switch (draft.type) {
    case "missed": {
      title = `${name} missed its scheduled run`;
      lines.push(`Due ${when(d.dueAt as number, now)}, and no run had started by ${when(d.deadline as number, now)} (grace ${formatDuration(d.graceMs as number)}).`);
      lines.push(`Schedule: ${def.schedule}${def.timezone ? ` (${def.timezone})` : ""}.`);
      lines.push(`Last run: ${run ? `${run.status} ${when(run.startedAt, now)}` : "never"}.`);
      break;
    }
    case "failed": {
      title = `${name} failed`;
      const n = d.consecutiveFailures as number;
      if (n > 1) lines.push(`${n} consecutive failures.`);
      if (run) {
        lines.push(`Started ${when(run.startedAt, now)}${run.durationMs !== null ? `, ran ${formatDuration(run.durationMs)}` : ""}.`);
        if (run.error) lines.push(`Error: ${firstLines(run.error, 4)}`);
        const out = tail(run.output, 8);
        if (out) lines.push(`Output (tail):\n${out}`);
      }
      break;
    }
    case "stuck": {
      title = `${name} is stuck`;
      if (run) {
        lines.push(`Started ${when(run.startedAt, now)} and never reported finishing. Marked as timed out after ${formatDuration(run.durationMs ?? now - run.startedAt)}.`);
        const out = tail(run.output, 8);
        if (out) lines.push(`Output so far (tail):\n${out}`);
      }
      lines.push(`If the process was killed mid-run (a serverless timeout, a deploy), this is what that looks like.`);
      break;
    }
    case "slow": {
      title = `${name} was slow`;
      lines.push(`Took ${formatDuration(d.durationMs as number)}; the limit is ${formatDuration(d.thresholdMs as number)} (${d.basis}).`);
      if (run) lines.push(`Started ${when(run.startedAt, now)}.`);
      break;
    }
    case "over_budget": {
      title = `${name} went over budget`;
      for (const b of d.breaches as BudgetBreach[]) {
        lines.push(`${b.metric}: ${formatNumber(b.value)}, limit ${formatNumber(b.limit)} (${b.basis}).`);
      }
      if (run) lines.push(`Started ${when(run.startedAt, now)}.`);
      break;
    }
    case "recovered": {
      title = `${name} recovered`;
      const after = (d.after as string[]).map((c) => c.replace("_", " ")).join(", ");
      lines.push(`A run ${run ? when(run.startedAt, now) : "just now"} succeeded${after ? ` after: ${after}` : ""}.`);
      if (run?.durationMs !== null && run?.durationMs !== undefined) lines.push(`Ran ${formatDuration(run.durationMs)}.`);
      break;
    }
  }

  return {
    type: draft.type,
    job: name,
    definition: def,
    run,
    title,
    message: lines.join("\n"),
    details: d,
    at: now,
  };
}
