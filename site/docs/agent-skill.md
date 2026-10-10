---
title: Agent skill
description: An agent skill so the agent that writes a cron job also writes its monitor.
order: 10
group: Reference
---

# Agent skill

The repository ships `skills/cronwatch/SKILL.md`, a skill for Claude Code, Codex, Cursor, and the other agents that read the same format. It is listed [on skills.sh](https://www.skills.sh/cronwatchdev/cronwatch). With it installed, asking for "monitor this cron job" or "why did the nightly job fail" gets a workflow instead of a guess.

## Install

With the [skills](https://skills.sh) command, which asks which agents to install it for and whether to install it in the project or for every project:

```bash
npx skills add cronwatchdev/cronwatch
```

Or, for Claude Code alone, copy the file into a project or your user skills:

```bash
# in a project
mkdir -p .claude/skills
curl -sL https://raw.githubusercontent.com/cronwatchdev/cronwatch/main/skills/cronwatch/SKILL.md \
  -o .claude/skills/cronwatch/SKILL.md --create-dirs

# or for every project
curl -sL https://raw.githubusercontent.com/cronwatchdev/cronwatch/main/skills/cronwatch/SKILL.md \
  -o ~/.claude/skills/cronwatch/SKILL.md --create-dirs
```

## What it teaches

**Adding monitoring.** Find where the job runs, pick the store the app already has, declare the job once with its real schedule and timezone, wrap the work, mount the routes, make sure something calls the check, add a channel. It tells the agent to ask before adding dependencies and to keep job names stable. It covers every language CronWatch has: TypeScript, and in a Ruby, Python, PHP, Go, Rust, Elixir, Java, or .NET app it uses that language's package instead, with its install, client, and store, how to wrap a job, the check, the dashboard, the handler for a platform that calls a URL, and the channels. In a Rails app, say, that is the install generator, `cronwatch` in ActiveJob and Sidekiq classes (or `schedule: :from_scheduler`), `Cronwatch::CheckJob` on the scheduler, and `Cronwatch::Web` mounted in the routes; in WordPress, Laravel, Symfony, Drupal, or Craft CMS, and with the Go, Rust, Elixir, Java, and .NET schedulers, the integration that watches jobs with little or no code.

**Investigating.** With the [MCP server](/docs/mcp/) configured: list jobs, read the failing run's error and output before changing code, fix the cause rather than the monitor, silence only during a known fix, and confirm recovery after deploying.

**The vocabulary.** What missed, failed, stuck, slow, over budget, and recovered mean, so the agent explains an alert correctly.

Pair it with the MCP server and the agent can go from "the digest didn't arrive" to a pull request with the fix and a confirmation that the next run recovered.
