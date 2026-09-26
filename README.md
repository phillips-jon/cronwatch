# CronWatch

Cron and scheduled-job monitoring that lives inside your app. Wrap a job once; CronWatch records every run in a database you already have and tells you when a run is missed, fails, gets stuck, runs slow or goes over budget. No server to run, no account to make. MIT.

**Site and docs:** [cronwatch.dev](https://cronwatch.dev)

```ts
// lib/cronwatch.ts
import { cronwatch } from "@cronwatch/sdk";
import { sqlite } from "@cronwatch/sdk/sqlite";
import { slack } from "@cronwatch/sdk/slack";

export const cw = cronwatch({
  store: sqlite({ path: "./data/cronwatch.db" }),
  alerts: [slack({ webhookUrl: process.env.SLACK_WEBHOOK_URL! })],
});

export const nightlyReport = cw.job("nightly-report", {
  schedule: "0 2 * * *", timezone: "UTC", grace: "15m", expect: "Report written",
});
```

```ts
// app/api/cron/nightly-report/route.ts: checks Authorization: Bearer CRON_SECRET
import { nightlyReport } from "@/lib/cronwatch";

export const GET = nightlyReport.handler(async (job) => {
  const report = await buildReport();
  job.log("Report written:", report.path);
  job.metric("cost", report.usdCost);
});
```

```ts
// app/cronwatch/[[...path]]/route.ts: a dashboard and JSON API behind CRONWATCH_TOKEN
import { cw } from "@/lib/cronwatch";

export const { GET, POST, DELETE } = cw.routes();
```

## Packages

| Package | What |
|---|---|
| [`@cronwatch/sdk`](packages/sdk) | the library: jobs, runs, checks, stores (memory, SQLite, Postgres), alerts (Slack, Discord, webhook), dashboard and API, optional Claude triage |
| [`@cronwatch/mcp`](packages/mcp) | an MCP server so Claude Code, Cursor and other agents can list jobs, read failures, run a check and silence alerts |
| [`skills/cronwatch`](skills/cronwatch) | a Claude Code skill: how to add monitoring to a job and how to investigate a failure |
| [`site`](site) | cronwatch.dev, a static landing page and docs |

## Installing

The SDK needs Node 22 or newer and depends only on `croner`. Each driver is an optional peer, installed only when you use its entry point:

| Entry point | Install |
|---|---|
| `@cronwatch/sdk/sqlite` | `better-sqlite3` (and `@types/better-sqlite3` for TypeScript) |
| `@cronwatch/sdk/postgres` | `pg` (and `@types/pg` for TypeScript) |
| `@cronwatch/sdk/anthropic` | `@anthropic-ai/sdk` 0.115 or newer |

The store entry points' type declarations refer to the driver's types, so a TypeScript project using them without `@types/better-sqlite3` or `@types/pg` fails with TS7016 unless `skipLibCheck` is on. The package ships ESM and CommonJS, each with its own types.

## Why a library and not a service

A hosted monitor gives you an observer that is alive when your job is not. That is real, and it is the one thing a library cannot do: if your whole app is down, nothing inside it can alert (pair it with any uptime monitor for that case). Everything else, from a job that never fires to one that costs three times what it should, is caught from within, with your run history in your own database and nothing to sign up for.

## Development

Develop on Node 24 (`.nvmrc`); CI also runs Node 22, the oldest supported (better-sqlite3 13 needs it). Postgres tests run when `CRONWATCH_TEST_PG` points at a database.

```bash
npm ci
npm run check          # dash check, typecheck, tests
npm run build          # every package and the site
npm run dev --workspace site    # the site on http://localhost:4321, rebuilding on change
npm run check:packages # pack both packages and use them from a scratch project (after build)
```

`npm run check:dashes` fails on an em or en dash in any tracked text file; CI also checks the commit messages.

## Deploying the site

Once CI passes on a push to `main`, `.github/workflows/deploy.yml` runs the deploy script on the server, which builds a release on the server beside the live one and switches a symlink only when the build checks out. `deploy/README.md` has the server layout, the one-time setup and the rollback command.

## License

MIT, see [LICENSE](LICENSE).
