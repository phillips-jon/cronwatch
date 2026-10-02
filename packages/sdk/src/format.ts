import { beyondDates, formatDuration, formatRelative, isoTime } from "./duration.js";
import { formatNumber } from "./evaluate.js";
import type { Alert, AlertDraft, StoredJobDefinition } from "./types.js";

function when(at: number | null | undefined, now: number): string {
  if (at === null || at === undefined) return "never";
  const iso = isoTime(at);
  if (iso === null) return beyondDates(at);
  return `${iso.replace("T", " ").slice(0, 19)} UTC (${formatRelative(at, now)})`;
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

/** "Error: x" for a bare message, but not "Error: TypeError: x" for one that already names itself. */
function errorLine(error: string): string {
  const text = firstLines(error, 4);
  return /^[A-Za-z_$][\w$]*: /.test(text) ? text : `Error: ${text}`;
}

/** Turns a draft into the title and message every channel shows. */
export function composeAlert(draft: AlertDraft, def: StoredJobDefinition, now: number): Alert {
  const name = def.name;
  const run = draft.run;
  let title: string;
  const lines: string[] = [];

  switch (draft.type) {
    case "missed": {
      const d = draft.details;
      title = `${name} missed its scheduled run`;
      lines.push(`Due ${when(d.dueAt, now)}, and no run had started by ${when(d.deadline, now)} (grace ${formatDuration(d.graceMs)}).`);
      lines.push(`Schedule: ${def.schedule}${def.timezone ? ` (${def.timezone})` : ""}.`);
      lines.push(`Last run: ${run ? `${run.status} ${when(run.startedAt, now)}` : "never"}.`);
      break;
    }
    case "failed": {
      title = `${name} failed`;
      const n = draft.details.consecutiveFailures;
      if (n > 1) lines.push(`${n} consecutive failures.`);
      if (run) {
        lines.push(`Started ${when(run.startedAt, now)}${run.durationMs !== null ? `, ran ${formatDuration(run.durationMs)}` : ""}.`);
        if (run.error) lines.push(errorLine(run.error));
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
      const d = draft.details;
      title = `${name} was slow`;
      lines.push(`Took ${formatDuration(d.durationMs)}; the limit is ${formatDuration(d.thresholdMs)} (${d.basis}).`);
      if (run) lines.push(`Started ${when(run.startedAt, now)}.`);
      break;
    }
    case "over_budget": {
      title = `${name} went over budget`;
      for (const b of draft.details.breaches) {
        lines.push(`${b.metric}: ${formatNumber(b.value)}, limit ${formatNumber(b.limit)} (${b.basis}).`);
      }
      if (run) lines.push(`Started ${when(run.startedAt, now)}.`);
      break;
    }
    case "under_floor": {
      title = `${name} fell short`;
      for (const b of draft.details.breaches) {
        lines.push(b.basis === "floor" ? `${b.metric}: ${formatNumber(b.value)}, below the floor of ${formatNumber(b.limit)}.` : `${b.metric}: ${formatNumber(b.value)} (${b.basis}).`);
      }
      if (run) lines.push(`Started ${when(run.startedAt, now)}.`);
      break;
    }
    case "recovered": {
      if (draft.details.reason === "unscheduled") {
        title = `${name} is no longer scheduled`;
        const since = draft.details.since;
        lines.push(`${since === undefined ? "" : `Missed since ${when(since, now)}. `}It has no schedule now, so nothing is due; the missed alert is closed.`);
        break;
      }
      title = `${name} recovered`;
      const after = draft.details.after.map((c) => c.replace("_", " ")).join(", ");
      lines.push(`A run ${run ? when(run.startedAt, now) : "just now"} succeeded${after ? ` after: ${after}` : ""}.`);
      if (run?.durationMs !== null && run?.durationMs !== undefined) lines.push(`Ran ${formatDuration(run.durationMs)}.`);
      break;
    }
  }

  return { ...draft, job: name, definition: def, title, message: lines.join("\n"), at: now };
}
