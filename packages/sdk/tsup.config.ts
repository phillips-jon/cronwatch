import { defineConfig } from "tsup";

export default defineConfig({
  entry: {
    index: "src/index.ts",
    sqlite: "src/stores/sqlite.ts",
    postgres: "src/stores/postgres.ts",
    slack: "src/alerts/slack.ts",
    discord: "src/alerts/discord.ts",
    webhook: "src/alerts/webhook.ts",
    anthropic: "src/triage/anthropic.ts",
  },
  format: ["esm", "cjs"],
  dts: true,
  sourcemap: true,
  clean: true,
  splitting: false,
  treeshake: true,
  target: "node20",
  platform: "node",
  external: ["better-sqlite3", "pg", "@anthropic-ai/sdk"],
});
