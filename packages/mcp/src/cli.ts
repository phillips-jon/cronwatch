#!/usr/bin/env node
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { createServer } from "./server.js";

const args = process.argv.slice(2);
const flag = (name: string): string | undefined => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : undefined;
};

if (args.includes("--help") || args.includes("-h")) {
  console.log(`cronwatch-mcp: an MCP server for an app that uses @cronwatch/sdk.

  CRONWATCH_URL    where cw.routes() is mounted, e.g. https://app.example.com/cronwatch
  CRONWATCH_TOKEN  the token those routes expect

Set them in the environment. --url and --token work too, but a flag shows up
in the process list (ps) for anyone on the machine, so prefer the variable for
the token. Add it to Claude Code with:

  claude mcp add cronwatch -e CRONWATCH_URL=https://app.example.com/cronwatch -e CRONWATCH_TOKEN=... -- npx -y @cronwatch/mcp
`);
  process.exit(0);
}

const baseUrl = flag("--url") ?? process.env.CRONWATCH_URL;
const token = flag("--token") ?? process.env.CRONWATCH_TOKEN ?? null;

if (baseUrl) {
  try {
    const { protocol, hostname } = new URL(baseUrl);
    if (protocol === "http:" && !["localhost", "127.0.0.1", "[::1]"].includes(hostname)) {
      console.error(`cronwatch-mcp: ${baseUrl} is plain http, so the token travels unencrypted; use https.`);
    }
  } catch {
    console.error(`cronwatch-mcp: CRONWATCH_URL "${baseUrl}" is not a URL.`);
    process.exit(2);
  }
}
if (!baseUrl) {
  console.error("cronwatch-mcp: set CRONWATCH_URL (or pass --url) to where cw.routes() is mounted, e.g. https://app.example.com/cronwatch");
  process.exit(2);
}
if (!token) {
  console.error("cronwatch-mcp: no CRONWATCH_TOKEN given; this only works against routes mounted with token: null. For an app in development without a token, use the one in the sign-in link it printed to its log.");
}

const server = createServer({ baseUrl, token });
const transport = new StdioServerTransport();
await server.connect(transport);
