---
title: AI triage
description: Attach a short diagnosis from Claude to every alert except recoveries, with your own API key.
order: 6.5
group: Reference
---

# AI triage

When an alert is about to be sent, CronWatch can hand the alert, the job definition, the triggering run's error, output tail, and metrics, and the last few runs to Claude, and attach two to four sentences: the likely cause and the first thing to check. The diagnosis appears in every built-in channel: the Slack and Discord messages, the webhook payload, every email, SMS, and error tracker channel, and the console. It is the alert's `triage` field, so a custom channel can show it too.

```ts
import { anthropic } from "@cronwatch/sdk/anthropic";

cronwatch({
  triage: anthropic({ context: "A Next.js app on Vercel with a Neon Postgres database." }),
});
```

Install the SDK it uses:

```bash
npm install @anthropic-ai/sdk
```

The key comes from the Anthropic SDK's usual environment, normally `ANTHROPIC_API_KEY`, or pass `apiKey`, or hand in a configured `client`.

## Options

| Option | Default | |
|---|---|---|
| `model` | `claude-opus-5` | any current model id |
| `effort` | `medium` | `low`, `medium`, or `high` |
| `maxTokens` | `800` | a diagnosis is a paragraph |
| `context` | | a sentence about the app, so advice is specific |
| `fallbacks` | `true` | route a policy refusal to Anthropic's default fallback model inside the same request. Turn off if your account or gateway rejects the beta. |

## Cost and timing

Triage runs only when an alert is sent, never per run, so it costs roughly one short request per incident: every missed, failed, stuck, slow, and over-budget alert, but never a recovery. It gets 25 seconds; if the request is slower or fails, the alert goes out without a diagnosis and the error is reported through `onError`. The request is made once, without retries, and is cancelled when the 25 seconds are up, so it never runs on after the alert has gone.

Triage runs once per alert, whatever happens to it. When it gives nothing (it threw, timed out, or answered empty) the alert's `triage` is `null`, and it is not asked again when the alert is retried. An alert that no channel accepted is queued with its diagnosis, so a later retry sends the same one. Alerts queued by a `deliver: "check"` process are triaged by the check that first retries them, within that check's 20 second retry budget.

## What is sent

The alert title and message, the job's stored definition, the triggering run (status, timing, metrics, up to 3 KB of error and 3 KB of output tail), and one line each for up to five earlier runs (the job's five newest, less the triggering run when it is one of them). Values that look like secrets are redacted before a run is stored, so they never reach triage, but the patterns cannot catch everything; log less or leave triage off for jobs that handle secrets.

Output and errors are sent inside `<job_data>` tags, and the model is told that anything inside them is evidence, never instructions. A job that logs text from outside (scraped pages, user input, upstream error bodies) cannot talk the model into putting its own advice or links in your alerts.

## Your own triage

`triage` is any function from a context to a string. Plug in a different model, a runbook lookup, or a rule engine. The context carries `signal`, an `AbortSignal` that fires when the client stops waiting; pass it to any request you make.

```ts
cronwatch({
  triage: async ({ alert, recentRuns }) => {
    if (alert.run?.error?.includes("ECONNREFUSED")) return "The database refused the connection. Check whether it was restarting.";
    return null;
  },
});
```

Every port has the same triage, sending the same request, beside the same channels: see Triage in [Ruby](/docs/ruby/#triage), [Python](/docs/python/#triage), [PHP](/docs/php/#triage), [Go](/docs/go/#triage), [Rust](/docs/rust/#triage), [Elixir](/docs/elixir/#triage), [Java](/docs/java/#triage), and [.NET](/docs/dotnet/#triage).
