---
title: MCP server
description: Give Claude Code, Cursor or any MCP client read and control access to your jobs.
order: 9
---

# MCP server

`@cronwatch/mcp` is a Model Context Protocol server over stdio. It talks to the JSON API your app mounts with its dashboard, which every port serves at the same paths, so it works the same with a TypeScript, Ruby, Python, PHP, Go or Rust app. It needs a URL and the token, and nothing else. It runs on Node through `npx`; your app does not need Node for anything else.

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

## Setting the URL and token

**`CRONWATCH_URL`** is where your app serves the dashboard, the same address you open it at in a browser:

| Your app | `CRONWATCH_URL` |
|---|---|
| TypeScript, `cw.routes()` | the mount point, `https://yourapp.com/cronwatch` by default |
| Rails, `mount Cronwatch::Web` | the mount point, `https://yourapp.com/cronwatch` |
| Django, `cronwatch.django.urls` | the prefix you include it under |
| Python, PHP, Go or Rust, the routes served by hand | the path you serve them at |
| Laravel or Symfony | `https://yourapp.com/cronwatch` ([Laravel](/docs/laravel/), [Symfony](/docs/symfony/)) |
| Drupal or Craft CMS | `https://yoursite.com/cronwatch`, once a token is set ([Drupal](/docs/drupal/), [Craft CMS](/docs/craft/)) |
| WordPress | `https://yoursite.com/wp-json/cronwatch/v1`, once the JSON API is on in the plugin's settings ([WordPress](/docs/wordpress/)) |

**`CRONWATCH_TOKEN`** is the token your app reads from its own `CRONWATCH_TOKEN` (the WordPress plugin's comes from its settings), the one you sign in to the dashboard with. Choose any long random string, set it in the app's environment, and give the same one here:

```bash
openssl rand -base64 32
```

For a local app in development without `CRONWATCH_TOKEN`, the app makes a token of its own and prints a sign-in link to its log on the first request; pass the `?token=` from that link as `CRONWATCH_TOKEN` here, or set one yourself.

`--url` and `--token` work as flags too, but a flag is visible to anyone who can list processes, so keep the token in the environment.

## Tools

| Tool | Does |
|---|---|
| `list_jobs` | every job with health, schedule, last run and next due. The place to start. |
| `get_job` | one job in detail: definition, open conditions, and recent runs with errors, output tails and metrics |
| `run_check` | look for missed and stuck runs now and send due alerts |
| `silence_job` | stop alerts for a duration, for example during a fix |
| `unsilence_job` | resume them |
| `forget_job` | remove a job that no longer exists in the code |
| `get_setup_guide` | the TypeScript code to add CronWatch to a job, so the agent writes it correctly (for Rails, point it at [Ruby on Rails](/docs/rails/)) |

The tools return prose an agent can act on, not raw JSON. A typical exchange: "why did invoice-run fail last night" becomes `get_job`, a read of the error and the earlier runs, and a suggested fix in your code.

## Security

The token gives the agent everything the dashboard can do. Give it a dedicated app deployment or accept that an agent can silence and forget jobs. Run history includes whatever your jobs logged; if that is sensitive, log less.

## The agent skill

A Claude Code skill in the repository teaches the workflow: where to declare jobs, how to wrap them, how to investigate a failure with these tools. See [Agent skill](/docs/agent-skill/).
