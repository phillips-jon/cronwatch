---
title: Convex
description: Convex crons calling Node actions wrapped with job.run(), a Postgres store outside Convex, and a cron for the check.
order: 3.37
group: More platforms
---

# Convex

Convex crons are declared in `convex/crons.ts` and call a mutation or an action on a schedule. CronWatch can watch them, with two conditions that come from how Convex runs code.

- **The SDK needs the Node runtime.** Queries, mutations and default-runtime actions run in Convex's own JavaScript runtime, which has no Node built-ins; the SDK uses `node:crypto`. Actions in a file that starts with `"use node"` run on Node, so the wrapped work lives in such an action.
- **The store is outside Convex.** Convex functions cannot keep a SQLite file, and there is no store that writes to Convex's own database. Use Postgres anywhere a Node action can reach over the network (Neon, Supabase, RDS).

If the job's work already lives in another app that has CronWatch, the simplest setup is a Convex cron whose action calls that app's `handler()` endpoint with `fetch`, and the run is recorded there. The rest of this page runs the job in Convex.

## Node actions for the job and the check

```ts
// convex/cronwatch.ts
"use node";

import { cronwatch } from "@cronwatch/sdk";
import { postgres } from "@cronwatch/sdk/postgres";
import { slack } from "@cronwatch/sdk/slack";
import { internal } from "./_generated/api";
import { internalAction } from "./_generated/server";

const cw = cronwatch({
  store: postgres({ connectionString: process.env.CRONWATCH_DATABASE_URL }),
  alerts: [slack({ webhookUrl: process.env.SLACK_WEBHOOK_URL! })],
  defaults: { timezone: "UTC" },     // Convex reads cron expressions in UTC
});

const digest = cw.job("daily-digest", { schedule: "0 6 * * *", grace: "10m", timeout: "15m" });

export const dailyDigest = internalAction({
  args: {},
  handler: async (ctx) => {
    await digest.run(async (job) => {
      const sent: number = await ctx.runMutation(internal.digest.send, {});
      job.metric("emails", sent);
    });
  },
});

export const check = internalAction({
  args: {},
  handler: async () => {
    const result = await cw.check();
    return { jobs: result.jobs.length, alerts: result.alerts.length };
  },
});
```

The action can do its reads and writes through `ctx.runQuery` and `ctx.runMutation`, as above, and the run covers all of it. Declare every job in this file, where the check runs, so a job that has never run is still known.

Set the variables with `npx convex env set CRONWATCH_DATABASE_URL ...` and `npx convex env set SLACK_WEBHOOK_URL ...`. `pg` loads an optional native module lazily, so mark it external in `convex.json`, which installs it on the server instead of bundling it:

```json
{
  "node": {
    "externalPackages": ["pg"]
  }
}
```

## The crons

```ts
// convex/crons.ts
import { cronJobs } from "convex/server";
import { internal } from "./_generated/api";

const crons = cronJobs();

crons.cron("daily digest", "0 6 * * *", internal.cronwatch.dailyDigest);
crons.interval("cronwatch check", { minutes: 5 }, internal.cronwatch.check);

export default crons;
```

Helpers like `crons.daily()` and `crons.hourly()` take an hour and minute in UTC; declare the job with the equivalent cron expression. For `crons.interval()`, declare `schedule: "every 30m"` to match `{ minutes: 30 }`.

## Limits that matter

- **Duration.** A Node action may run for 10 minutes. One stopped at that limit cannot record its end, so the run stays `running` until a check passes the job's `timeout` and marks it stuck. A `timeout` of `15m` reports it within a few minutes of the limit.
- **Skipped runs.** Convex runs at most one instance of a cron at a time, and skips a scheduled run when the previous one is still going. Nothing starts, so after the grace period CronWatch reports the slot missed.
- **No retries.** Convex does not retry actions, so each fire is one run.

## The dashboard

Convex HTTP actions run in the default runtime, not Node, so the dashboard cannot be served from Convex. Serve `cw.routes()` from any Node app that uses the same Postgres store (a small Hono or Next.js app will do, see [Servers and scripts](/docs/node/)), and point the [MCP server](/docs/mcp/) at that URL.
