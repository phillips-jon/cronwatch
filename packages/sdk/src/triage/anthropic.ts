import Anthropic from "@anthropic-ai/sdk";
import { formatDuration } from "../duration.js";
import type { TriageContext, TriageFn } from "../types.js";

export interface AnthropicTriageOptions {
  /** Defaults to what the Anthropic SDK resolves: ANTHROPIC_API_KEY, or an `ant auth login` profile. */
  apiKey?: string;
  /** Bring a configured client instead. */
  client?: Anthropic;
  /** Default "claude-opus-5". */
  model?: string;
  /** How hard the model thinks. Default "medium"; a stack trace rarely needs more. */
  effort?: "low" | "medium" | "high";
  /** Default 800. A diagnosis is a paragraph. */
  maxTokens?: number;
  /**
   * Route a policy refusal to Anthropic's default fallback model inside the
   * same request, so a diagnosis still comes back. On by default; turn off if
   * your account or gateway rejects the beta.
   */
  fallbacks?: boolean;
  /** Anything the model should know about this app: "A Next.js app on Vercel with a Neon database." */
  context?: string;
}

/** Under the client's 25 second wait, so the request ends on its own first. */
const REQUEST_TIMEOUT_MS = 24_000;

const SYSTEM =`You help an engineer understand why a scheduled job misbehaved. You are given the alert, the job's definition, the run that triggered it and a few earlier runs.

Reply with two to four sentences of plain prose: the most likely cause, and the first concrete thing to check or change. Be specific to the evidence given; if the evidence is thin, say what is missing rather than guessing. No headings, no lists, no preamble, no restating the error verbatim.`;

function describe(ctx: TriageContext): string {
  const { alert, recentRuns } = ctx;
  const run = alert.run;
  const lines: string[] = [];
  lines.push(`Alert: ${alert.type}. ${alert.title}`);
  lines.push(alert.message);
  lines.push("");
  lines.push(`Job definition: ${JSON.stringify(alert.definition)}`);
  if (run) {
    lines.push("");
    lines.push(`Triggering run: status ${run.status}, started ${new Date(run.startedAt).toISOString()}, duration ${run.durationMs === null ? "unknown" : formatDuration(run.durationMs)}, trigger ${run.trigger}`);
    if (Object.keys(run.metrics).length) lines.push(`Metrics: ${JSON.stringify(run.metrics)}`);
    if (run.error) lines.push(`Error:\n${run.error.slice(0, 3000)}`);
    if (run.output) lines.push(`Output (tail):\n${run.output.slice(-3000)}`);
  }
  const earlier = recentRuns.filter((r) => r.id !== run?.id).slice(0, 5);
  if (earlier.length) {
    lines.push("");
    lines.push("Earlier runs, newest first:");
    for (const r of earlier) {
      lines.push(`- ${r.status}, ${new Date(r.startedAt).toISOString()}, ${r.durationMs === null ? "unknown" : formatDuration(r.durationMs)}${r.error ? `, error: ${r.error.split("\n")[0]!.slice(0, 160)}` : ""}${Object.keys(r.metrics).length ? `, metrics ${JSON.stringify(r.metrics)}` : ""}`);
    }
  }
  return lines.join("\n");
}

/**
 * A triage function backed by Claude. Pass it as `triage` to cronwatch():
 *
 *   cronwatch({ triage: anthropic({ context: "A Next.js app on Vercel." }) })
 *
 * It runs only when an alert is sent (never per run), so cost is bounded by
 * how often things go wrong, and it never blocks an alert: the client gives
 * it 25 seconds and moves on without a diagnosis if it takes longer.
 */
export function anthropic(options: AnthropicTriageOptions = {}): TriageFn {
  const client = options.client ?? new Anthropic(options.apiKey ? { apiKey: options.apiKey } : {});
  const model = options.model ?? "claude-opus-5";
  const useFallbacks = options.fallbacks ?? true;

  return async (ctx) => {
    const user = (options.context ? `About this app: ${options.context}\n\n` : "") + describe(ctx);
    const response = await client.beta.messages.create({
      model,
      max_tokens: options.maxTokens ?? 800,
      system: SYSTEM,
      output_config: { effort: options.effort ?? "medium" },
      messages: [{ role: "user", content: user }],
      ...(useFallbacks ? { betas: ["server-side-fallback-2026-07-01"], fallbacks: "default" } : {}),
    }, {
      // One attempt that ends when the client stops waiting, rather than
      // retries that run on after the alert has gone out without a diagnosis.
      signal: ctx.signal,
      timeout: REQUEST_TIMEOUT_MS,
      maxRetries: 0,
    });
    if (response.stop_reason === "refusal") return null;
    const text = response.content
      .filter((block): block is Anthropic.Beta.BetaTextBlock => block.type === "text")
      .map((block) => block.text)
      .join("\n")
      .trim();
    return text || null;
  };
}
