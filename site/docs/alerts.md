---
title: Alerts
description: Slack, Discord, signed webhooks, the console, custom channels, and the alert payload.
order: 6
---

# Alerts

Pass any number of channels. Every alert goes to every channel at once; a channel that throws, or takes longer than 15 seconds, is reported through `onError` and never blocks the others. If no channel accepts an alert, each later check tries it again, once, until one does (see [Limits](/docs/limits/)).

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

Job output is shown inside a code block it cannot break out of, and messages never ping anyone, even when the output contains `@everyone`. Slack messages are escaped the same way.

## Webhook

POSTs the alert as JSON to any URL. With a `secret`, each request carries `X-CronWatch-Signature: sha256=<hex>`, the HMAC-SHA256 of the raw body. A failed request is reported with the URL's origin only, since a webhook's path often holds its credential.

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
  details: AlertDetails[type];       // depends on type, below
  triage?: string;                   // the diagnosis, when triage is configured
  at: number;                        // epoch ms
}
```

`Alert` is a union on `type`, so checking the type gives you typed `details`:

| `type` | `details` |
|---|---|
| `missed` | `{ dueAt, deadline, graceMs, lastRunAt }` |
| `failed`, `stuck` | `{ consecutiveFailures, threshold }` |
| `slow` | `{ durationMs, thresholdMs, basis }` |
| `over_budget` | `{ breaches: { metric, value, limit, basis }[] }` |
| `recovered` | `{ after: Condition[] }` |

```ts
custom("latency", (alert) => {
  if (alert.type === "slow") metrics.gauge("job.slow_ms", alert.details.durationMs);
});
```

## Errors outside jobs

`onError(error, where)` is called when a channel fails, triage times out, the store throws or pruning fails. The default prints to the console. Wire it to your error tracker:

```ts
cronwatch({ onError: (error, where) => Sentry.captureException(error, { tags: { where } }) });
```
