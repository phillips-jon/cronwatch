---
title: Alerts
description: Slack, Discord, signed webhooks, the console, custom channels, and the alert payload.
order: 6
---

# Alerts

Pass any number of channels. Every alert goes to every channel; a channel that throws is reported through `onError` and never blocks the others.

## Slack

An incoming webhook from [api.slack.com/messaging/webhooks](https://api.slack.com/messaging/webhooks).

```ts
import { slack } from "@cronwatch/sdk/slack";

slack({
  webhookUrl: process.env.SLACK_WEBHOOK_URL!,
  link: (alert) => `https://app.example.com/cronwatch/jobs/${alert.job}`,   // optional "open" link
});
```

## Discord

A channel webhook from Server Settings, Integrations.

```ts
import { discord } from "@cronwatch/sdk/discord";
discord({ webhookUrl: process.env.DISCORD_WEBHOOK_URL! });
```

## Webhook

POSTs the alert as JSON to any URL. With a `secret`, each request carries `X-CronWatch-Signature: sha256=<hex>`, the HMAC-SHA256 of the raw body.

```ts
import { webhook } from "@cronwatch/sdk/webhook";
webhook({ url: "https://hooks.example.com/cronwatch", secret: process.env.CRONWATCH_WEBHOOK_SECRET, headers: { "x-team": "billing" } });
```

Verifying on the receiving side:

```ts
import { createHmac, timingSafeEqual } from "node:crypto";

const expected = "sha256=" + createHmac("sha256", secret).update(rawBody).digest("hex");
const ok = timingSafeEqual(Buffer.from(expected), Buffer.from(request.headers.get("x-cronwatch-signature") ?? ""));
```

## Console and custom

The console channel is the default and prints the title and message. `custom()` wraps any function:

```ts
import { custom } from "@cronwatch/sdk";

custom("pagerduty", async (alert) => {
  if (alert.type === "recovered") return;
  await pagerduty.trigger({ summary: alert.title, details: alert.message });
});
```

## The alert payload

```ts
interface Alert {
  type: "missed" | "failed" | "stuck" | "slow" | "over_budget" | "recovered";
  job: string;
  definition: StoredJobDefinition;   // name, schedule, grace, timeout, budget...
  run: Run | null;                   // the run that triggered it, with error, output and metrics
  title: string;                     // "nightly-report failed"
  message: string;                   // a few lines of specifics
  details: Record<string, unknown>;  // per type: dueAt/deadline, durationMs/thresholdMs, breaches...
  triage?: string;                   // the diagnosis, when triage is configured
  at: number;                        // epoch ms
}
```

## Errors outside jobs

`onError(error, where)` is called when a channel fails, triage times out or pruning throws. The default prints to the console. Wire it to your error tracker:

```ts
cronwatch({ onError: (error, where) => Sentry.captureException(error, { tags: { where } }) });
```
