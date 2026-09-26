---
title: AI triage
description: Attach a short diagnosis from Claude to every failure alert, with your own API key.
order: 11
---

# AI triage

When an alert is about to be sent, CronWatch can hand the alert, the job definition, the triggering run's error, output tail and metrics, and the last few runs to Claude, and attach two to four sentences: the likely cause and the first thing to check. The diagnosis appears in the Slack or Discord message, the webhook payload, and the console.

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

The key comes from `ANTHROPIC_API_KEY`, or pass `apiKey`, or hand in a configured `client`.

## Options

| Option | Default | |
|---|---|---|
| `model` | `claude-opus-5` | any current model id |
| `effort` | `medium` | `low`, `medium` or `high` |
| `maxTokens` | `800` | a diagnosis is a paragraph |
| `context` | | a sentence about the app, so advice is specific |
| `fallbacks` | `true` | route a policy refusal to Anthropic's default fallback model inside the same request. Turn off if your account or gateway rejects the beta. |

## Cost and timing

Triage runs only when an alert is sent, never per run, so it costs roughly one short request per incident. It gets 25 seconds; if the request is slower or fails, the alert goes out without a diagnosis and the error is reported through `onError`. Recovery messages are never triaged.

## What is sent

The alert title and message, the job's stored definition, the triggering run (status, timing, metrics, up to 3 KB of error and 3 KB of output tail), and one line each for up to five earlier runs. If your jobs log secrets, they will be in the output; log less or leave triage off for those jobs.

## Your own triage

`triage` is any function from a context to a string. Plug in a different model, a runbook lookup, or a rule engine:

```ts
cronwatch({
  triage: async ({ alert, recentRuns }) => {
    if (alert.run?.error?.includes("ECONNREFUSED")) return "The database refused the connection. Check whether it was restarting.";
    return null;
  },
});
```
