---
title: Alerts
description: Slack, Discord, signed webhooks, email, SMS, error trackers, the console, custom channels, and the alert payload.
order: 6
group: Reference
---

# Alerts

Pass any number of channels. Every alert goes to every channel at once; a channel that throws, or takes longer than 15 seconds, is reported through `onError` and never blocks the others. If no channel accepts an alert, each later check tries it again, once, until one does. An alert is stored with the state that opens its condition before it is sent, so one whose process dies mid-send is sent by a later check (see [Limits](/docs/limits/)).

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

POSTs the alert as JSON to any URL: the [alert payload](#the-alert-payload) below, with `"schema": 1` as its first field. With a `secret`, each request carries `X-CronWatch-Signature: sha256=<hex>`, the HMAC-SHA256 of the raw body. A failed request is reported with the URL's origin only, since a webhook's path often holds its credential.

```ts
import { webhook } from "@cronwatch/sdk/webhook";
webhook({ url: "https://hooks.example.com/cronwatch", secret: process.env.CRONWATCH_WEBHOOK_SECRET, headers: { "x-team": "billing" } });
```

Verifying on the receiving side, with `signature(secret, body)` from the same entry point, the HMAC-SHA256 as lowercase hex (every port has it under that name):

```ts
import { timingSafeEqual } from "node:crypto";
import { signature } from "@cronwatch/sdk/webhook";

const expected = Buffer.from(`sha256=${await signature(secret, rawBody)}`);
const received = Buffer.from(request.headers.get("x-cronwatch-signature") ?? "");
const ok = received.length === expected.length && timingSafeEqual(received, expected);
```

`timingSafeEqual` throws when the two buffers differ in length, so compare the lengths first: a request with no signature, or a short one, is then refused rather than crashing the handler. Hash the raw body as it arrived, before any JSON parsing. Without the SDK, `createHmac("sha256", secret).update(rawBody).digest("hex")` from `node:crypto` gives the same hex.

## Email, SMS and error trackers

Each provider below is its own entry point, with nothing to install: they use only `fetch` and Web Crypto, so they run on Node, Cloudflare Workers, Deno and Bun. Every request gives up after 10 seconds. A failure names the provider and the URL's origin, with any key the channel holds cut out of the response it quotes. A redirect is treated as a failure rather than followed, here and for Slack, Discord and the webhook, so a key in a header never goes to another address. Every channel takes an optional `link: (alert) => string`, shown as an "Open" link.

### Email

All five email channels send the same message: the subject is the alert title (after `subjectPrefix`, if you set one), and the body is the title, the message, the triage and the link, as plain text and as a small HTML part with everything escaped and no remote images. They share these options:

| Option | |
|---|---|
| `from` | The sender, `"alerts@example.com"` or `"CronWatch <alerts@example.com>"`. The provider must allow it. |
| `to` | One address or an array. |
| `subjectPrefix` | Put before the title, `"[prod]"` say. |
| `link` | `(alert) => string`. Only `http` and `https` links are included. |

#### Resend

```ts
import { resend } from "@cronwatch/sdk/resend";
resend({ apiKey: process.env.RESEND_API_KEY!, from: "CronWatch <alerts@example.com>", to: "ops@example.com" });
```

Each request carries an `Idempotency-Key` derived from the alert, so Resend delivers a resent alert once.

#### Postmark

```ts
import { postmark } from "@cronwatch/sdk/postmark";
postmark({ serverToken: process.env.POSTMARK_SERVER_TOKEN!, from: "alerts@example.com", to: ["ops@example.com", "dev@example.com"] });
```

`messageStream` defaults to `"outbound"`, the transactional stream.

#### SendGrid

```ts
import { sendgrid } from "@cronwatch/sdk/sendgrid";
sendgrid({ apiKey: process.env.SENDGRID_API_KEY!, from: "alerts@example.com", to: "ops@example.com" });
```

`region: "eu"` sends through `api.eu.sendgrid.com`, for EU regional subusers.

#### Mailgun

```ts
import { mailgun } from "@cronwatch/sdk/mailgun";
mailgun({ apiKey: process.env.MAILGUN_API_KEY!, domain: "mg.example.com", from: "alerts@mg.example.com", to: "ops@example.com" });
```

`region: "eu"` is for a domain in Mailgun's EU region.

#### Amazon SES

Sends with the SES v2 `SendEmail` API, signed with AWS Signature Version 4, so no AWS SDK is needed. The from address (or its domain) must be a verified identity in `region`, and the credentials need `ses:SendEmail`.

```ts
import { ses } from "@cronwatch/sdk/ses";
ses({
  region: "us-east-1",
  accessKeyId: process.env.AWS_ACCESS_KEY_ID!,
  secretAccessKey: process.env.AWS_SECRET_ACCESS_KEY!,
  sessionToken: process.env.AWS_SESSION_TOKEN,   // optional, for temporary credentials
  from: "alerts@example.com",
  to: "ops@example.com",
});
```

`configurationSetName` is optional.

### SMS: Twilio

Texts each number in `to` separately, all at once. The message is the title, then as many lines of the message and triage as fit in `segments` SMS segments (3 by default, 10 at most, which keeps it inside Twilio's 1600 character limit), then the link, kept whole. Segments are counted as phones pack them: an extension character such as `{` or `€`, or an emoji, never straddles two. Recoveries are not texted unless you pass `recovered: true`.

```ts
import { twilio } from "@cronwatch/sdk/twilio";
twilio({
  accountSid: process.env.TWILIO_ACCOUNT_SID!,
  authToken: process.env.TWILIO_AUTH_TOKEN!,   // or apiKeySid and apiKeySecret
  from: "+15005550006",                         // or messagingServiceSid
  to: ["+15551110000", "+15552220000"],
});
```

The alert counts as sent when any number took it, so the next check never texts the numbers that already have it again; each number that refused it is reported to `onError` (with all but its last four digits hidden). Only when every number refuses it is the alert a failure, kept and retried at the next check, with an error that says how many failed. The credentials are trimmed of the spaces and newlines a paste leaves, and a redirect from Twilio is an error rather than followed, so the Authorization header goes nowhere else.

### Error trackers

These report each alert as an event, grouped so that each job's condition is one issue: the fingerprint (or grouping key) is `cronwatch:<job>:<type>`. Failed, stuck and missed are errors, slow, over budget and under floor are warnings, and a recovery is informational.

#### Sentry

```ts
import { sentry } from "@cronwatch/sdk/sentry";
sentry({ dsn: process.env.SENTRY_DSN!, environment: "production", release: "app@1.2.3" });
```

Sends an event to the project's envelope endpoint, tagged `job` and `type`, with the triage, link, details and run under Additional Data. The event id is derived from the alert, so Sentry drops a resend. `recovered: false` leaves recoveries out.

#### Honeybadger

```ts
import { honeybadger } from "@cronwatch/sdk/honeybadger";
honeybadger({ apiKey: process.env.HONEYBADGER_API_KEY!, environment: "production" });
```

Reports an error notice (not a Check-in, which is a separate Honeybadger product) with a class such as `CronWatch::Failed`. Honeybadger has no levels, so recoveries are only sent with `recovered: true`. For the EU region, pass `endpoint: "https://eu-api.honeybadger.io"`.

#### Datadog

```ts
import { datadog } from "@cronwatch/sdk/datadog";
datadog({ apiKey: process.env.DD_API_KEY!, site: "datadoghq.eu", tags: ["env:prod"] });
```

Posts to the Events API with `alert_type` `error`, `warning` or `success`, an aggregation key per job and type, and the tags `cronwatch`, `job:<name>` and `alert:<type>`. `site` defaults to `datadoghq.com`; `host` is optional. Datadog rejects events more than 18 hours old, which matters only if an alert was queued that long.

#### Rollbar

```ts
import { rollbar } from "@cronwatch/sdk/rollbar";
rollbar({ accessToken: process.env.ROLLBAR_ACCESS_TOKEN!, environment: "production" });
```

Needs a token with the `post_server_item` scope. `recovered: false` leaves recoveries out.

#### Bugsnag

```ts
import { bugsnag } from "@cronwatch/sdk/bugsnag";
bugsnag({ apiKey: process.env.BUGSNAG_API_KEY!, releaseStage: "production" });
```

Sends a handled event with a grouping hash per job and type and the details under a `cronwatch` metadata tab. Recoveries are only sent with `recovered: true`. `endpoint` points it at an on-premise install.

#### New Relic

```ts
import { newrelic } from "@cronwatch/sdk/newrelic";
newrelic({ accountId: 1234567, apiKey: process.env.NEW_RELIC_LICENSE_KEY!, region: "us" });
```

Records a `CronWatchAlert` custom event (rename it with `eventType`) with `job`, `alertType`, `severity`, `title`, `message`, `triage`, `link`, `runId`, `runStatus` and `durationMs`, which you can chart or alert on with NRQL: `SELECT count(*) FROM CronWatchAlert WHERE severity = 'error' FACET job`. The key is an ingest license key; `region: "eu"` is for EU accounts.

## Console and custom

The console channel is the default and prints the title and message. `custom()` wraps any function:

```ts
import { custom } from "@cronwatch/sdk";

custom("pagerduty", async (alert) => {
  if (alert.type === "recovered") return;
  await pagerduty.trigger({ summary: alert.title, details: alert.message });
});
```

## Processes that cannot send

A job can run somewhere that cannot reach Slack or a mail relay: a sandboxed backup unit, a worker with no network, a script without the app's secrets. Give that process `deliver: "check"`:

```ts
const recorder = cronwatch({ store: sqlite({ path: "/var/lib/app/cronwatch.db" }), deliver: "check" });
```

It still records every run and evaluates it, but instead of sending an alert it queues it with the job's state. The next check in a process that sends normally (the web server's `cw.startChecking()`, or whatever calls the check endpoint) delivers it, adds triage if that process has it, and marks it sent. A failed backup reaches you a minute later rather than never. Both processes must use the same store. Calling `cw.startChecking()` in the recording process is allowed but sends nothing, so it warns once on the console.

## The alert payload

What a custom channel is given, and, with `schema` added, what the webhook posts:

```ts
interface Alert {
  type: "missed" | "failed" | "stuck" | "slow" | "over_budget" | "under_floor" | "recovered";
  job: string;
  definition: StoredJobDefinition;   // name, schedule, grace, timeout, budget...
  run: Run | null;                   // the run that triggered it, with error, output and metrics
  title: string;                     // "nightly-report failed"
  message: string;                   // a few lines of specifics
  details: AlertDetails[type];       // depends on type, below
  triage?: string | null;            // the diagnosis, when triage is configured; null when it gave none
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
| `under_floor` | `{ breaches: { metric, value, limit, basis }[] }`; `limit` is the floor, or for a metric without one the lowest of the runs it was judged against |
| `recovered` | `{ after: Condition[], reason?: "unscheduled", since?: number }`; `reason` is set when a check closed missed because the job no longer has a schedule, and `since` is when missed opened |

```ts
custom("latency", (alert) => {
  if (alert.type === "slow") metrics.gauge("job.slow_ms", alert.details.durationMs);
});
```

### The webhook's schema

The webhook's body is the alert after one more field, `"schema": 1`, which comes first: every CronWatch library, in every language, posts the same fields. Its JSON Schema is published at [cronwatch.dev/schemas/webhook/1.json](/schemas/webhook/1.json) (draft 2020-12), for a receiver to validate against or generate types from.

What stays the same within `schema: 1`: every field above, the `details` of each type, the `X-CronWatch-Signature` header and its HMAC-SHA256. A release may add a field, a `details` field, an alert type, a condition or a run status, so ignore what you do not know rather than refusing it. A change that is not additive would come with `"schema": 2`, in a major release.

What is not promised: the wording of `title` and `message`, and what the other channels' messages look like. They are written for people and may read better in any release. Parse the fields, not the text: `type` rather than "failed" in the title, `details.durationMs` rather than the message's duration.

## Errors outside jobs

`onError(error, where)` is called when a channel fails, triage times out, the store throws, pruning fails, a custom `redact` throws, a job cannot be evaluated, or queued alerts are dropped past twenty. The default prints to the console. Wire it to your error tracker:

```ts
cronwatch({ onError: (error, where) => Sentry.captureException(error, { tags: { where } }) });
```

Every port has the same channels, sending the same requests, and the same triage: see Alerts in [Ruby](/docs/ruby/#alerts), [Python](/docs/python/#alerts), [PHP](/docs/php/#alerts), [Go](/docs/go/#alerts), [Rust](/docs/rust/#alerts), [Elixir](/docs/elixir/#alerts), [Java](/docs/java/#alerts) and [.NET](/docs/dotnet/#alerts).
