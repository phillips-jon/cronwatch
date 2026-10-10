---
title: About
description: Why CronWatch exists, how it works, and who makes it.
---

# Cron monitoring that lives inside your app

CronWatch watches the scheduled jobs your application already runs. Wrap a job once and it records every run in a database you already have, then tells you when a run is missed, fails, gets stuck, runs slow, goes over budget, or quietly does nothing. Each problem opens one alert and closes with a recovery, so a bad night is a short thread rather than a flood.

It is a library, not a service. There is no server to run, no account to make, and nothing is sent to cronwatch.dev: runs, output, and alerts stay in your own database, and the alert channels talk straight to Slack, email, or whatever you connect, under your own account. A dashboard and JSON API mount inside your app, and an MCP server and agent skill let Claude read the same history and help work out why a job broke.

The same library ships for TypeScript, Ruby, Python, PHP, Go, Rust, Elixir, Java, and .NET, each a port of one design and held to the same behaviour by a shared conformance suite. It is open source under the MIT license.

## Who makes it

CronWatch is made and maintained by [Jon C. Phillips](https://joncphillips.com), a product designer and developer who has spent over twenty years launching web products.

Questions, bug reports, and ideas are welcome on [GitHub](https://github.com/cronwatchdev/cronwatch/issues) or through the [contact form](/contact/).

[Read the docs](/docs/) · [View on GitHub](https://github.com/cronwatchdev/cronwatch)
