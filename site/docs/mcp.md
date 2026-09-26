---
title: MCP server
description: Give Claude Code, Cursor or any MCP client read and control access to your jobs.
order: 9
---

# MCP server

`@cronwatch/mcp` is a Model Context Protocol server over stdio. It talks to the JSON API your app mounts with `cw.routes()`, so it needs a URL and the token, and nothing else.

## Claude Code

```bash
claude mcp add cronwatch \
  -e CRONWATCH_URL=https://app.example.com/cronwatch \
  -e CRONWATCH_TOKEN=your-token \
  -- npx -y @cronwatch/mcp
```

## Other clients

Any client that launches stdio servers:

```json
{
  "mcpServers": {
    "cronwatch": {
      "command": "npx",
      "args": ["-y", "@cronwatch/mcp"],
      "env": { "CRONWATCH_URL": "https://app.example.com/cronwatch", "CRONWATCH_TOKEN": "your-token" }
    }
  }
}
```

`--url` and `--token` work as flags too. For a local app leave the token out and the routes open in development.

## Tools

| Tool | Does |
|---|---|
| `list_jobs` | every job with health, schedule, last run and next due. The place to start. |
| `get_job` | one job in detail: definition, open conditions, and recent runs with errors, output tails and metrics |
| `run_check` | look for missed and stuck runs now and send due alerts |
| `silence_job` | stop alerts for a duration, for example during a fix |
| `unsilence_job` | resume them |
| `forget_job` | remove a job that no longer exists in the code |
| `get_setup_guide` | the code to add CronWatch to a job, so the agent writes it correctly |

The tools return prose an agent can act on, not raw JSON. A typical exchange: "why did invoice-run fail last night" becomes `get_job`, a read of the error and the earlier runs, and a suggested fix in your code.

## Security

The token gives the agent everything the dashboard can do. Give it a dedicated app deployment or accept that an agent can silence and forget jobs. Run history includes whatever your jobs logged; if that is sensitive, log less.

## The agent skill

A Claude Code skill in the repository teaches the workflow: where to declare jobs, how to wrap them, how to investigate a failure with these tools. See [Agent skill](/docs/agent-skill/).
