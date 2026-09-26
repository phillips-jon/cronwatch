# @cronwatch/mcp

An MCP server for apps that use [`@cronwatch/sdk`](https://www.npmjs.com/package/@cronwatch/sdk). It talks to the JSON API the app mounts with `cw.routes()`, so Claude Code, Cursor or any MCP client can list jobs, read a failing run's error and output, run a check, and silence a job during a fix.

```bash
claude mcp add cronwatch \
  -e CRONWATCH_URL=https://app.example.com/cronwatch \
  -e CRONWATCH_TOKEN=your-token \
  -- npx -y @cronwatch/mcp
```

Any stdio MCP client:

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

## Tools

| Tool | |
|---|---|
| `list_jobs` | every job with health, schedule, last run and next due |
| `get_job` | one job with recent runs: errors, output tails, metrics |
| `run_check` | look for missed and stuck runs now and send due alerts |
| `silence_job`, `unsilence_job` | pause and resume alerts for a job |
| `forget_job` | remove a job that no longer exists in the code |
| `get_setup_guide` | the code to add CronWatch to a job |

The token grants everything the dashboard can do. Docs: [cronwatch.dev/docs/mcp](https://cronwatch.dev/docs/mcp/). MIT.
