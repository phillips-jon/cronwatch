import { defineConfig } from "tsup";

export default defineConfig({
  entry: {
    index: "src/index.ts",
    sqlite: "src/stores/sqlite.ts",
    postgres: "src/stores/postgres.ts",
    d1: "src/stores/d1.ts",
    slack: "src/alerts/slack.ts",
    // These entry points name what they export, so the helpers their
    // modules share with the tests and the conformance script stay internal.
    discord: "src/entries/discord.ts",
    webhook: "src/entries/webhook.ts",
    resend: "src/alerts/resend.ts",
    postmark: "src/alerts/postmark.ts",
    sendgrid: "src/alerts/sendgrid.ts",
    mailgun: "src/alerts/mailgun.ts",
    ses: "src/alerts/ses.ts",
    twilio: "src/entries/twilio.ts",
    sentry: "src/entries/sentry.ts",
    honeybadger: "src/alerts/honeybadger.ts",
    datadog: "src/alerts/datadog.ts",
    rollbar: "src/alerts/rollbar.ts",
    bugsnag: "src/alerts/bugsnag.ts",
    newrelic: "src/alerts/newrelic.ts",
    anthropic: "src/triage/anthropic.ts",
    "pg-cron": "src/entries/pg-cron.ts",
    node: "src/node.ts",
  },
  format: ["esm", "cjs"],
  dts: true,
  sourcemap: true,
  clean: true,
  splitting: false,
  treeshake: true,
  target: "node22",
  platform: "node",
  external: ["better-sqlite3", "pg", "@anthropic-ai/sdk"],
});
