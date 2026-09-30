---
title: What it catches
description: The conditions CronWatch reports, how each is decided, baselines, expect rules, budgets and silence.
order: 5
group: Reference
---

# What it catches

Every condition is opened once, sends one alert, and stays open until it clears. Once it has cleared, the next successful run that leaves nothing open sends one **recovered** message naming what was recovered from, or, for a job that lost its schedule while missed, the next check does (see [recovered](#recovered)). A job failing all night pages you once.

## missed

The schedule said a run was due and none started within the grace period. Decided by `cw.check()`; see [Schedules](/docs/schedules/). Closes when a run starts; the recovered message follows the next successful run. If the job loses its schedule while missed is open, the next check closes it with a recovery of its own.

## failed

Any of:

- the function threw (the error's name, message and the first stack frames are recorded),
- the handler returned a `Response` with status 400 or above,
- the job has an `expect` rule and the output did not satisfy it.

Alerts on the first failure by default. Set `failuresBeforeAlert: 3` to wait for the third consecutive one, for jobs that flake and self-heal. It must be a whole number, 1 or more; `cw.job()` throws otherwise. Consecutive failures are counted either way and shown on the dashboard.

## stuck

A run started and never reported finishing within `timeout`. Marked as `timeout` by the next check, counted as a failure. Usually a killed process: a serverless limit, a deploy, an OOM. Closes when the next run starts; the recovered message follows the next successful run.

A run started with `job.start()` and never finished is caught the same way. See [Runs that span calls](#runs-that-span-calls).

## slow

A successful run took longer than it should. The threshold is:

- `maxDuration`, if the job sets one, or
- twice the p95 of the job's last twenty successful runs, once there are at least five to compare against, with a floor of ten seconds so a job that usually takes 200ms is not called slow at 500ms.

Closes when a successful run is back under the threshold.

## over_budget

A metric reported with `job.metric(name, value)` went above its limit. The limit is:

- `budget[name]`, if the job sets one (a finite number, 0 or more; `budget: { errors: 0 }` alerts on any error), or
- three times the median of that metric over the last twenty successful runs, once there are at least five.

All breaching metrics are listed in one alert. Closes when a run's metrics are all within limits again.

## recovered

A run succeeded and no condition remains open. The message names everything that alerted and has cleared since the last recovery, for example "after: missed, failed". A condition that closed while another stayed open waits for this message, so every alert is answered by a recovery once the job is healthy again.

One recovery comes from a check rather than a run. When a job with missed open no longer has a schedule (it was declared again without one, or the [pg_cron reader](/docs/supabase/) retired a job that was renamed, unscheduled or paused), nothing is due any more, so the next check closes missed and sends a recovered alert:

```text
nightly is no longer scheduled
Missed since 2026-01-05 03:15:00 UTC (6h ago). It has no schedule now, so nothing is due; the missed alert is closed.
```

- Its details are `{ after: ["missed"], reason: "unscheduled", since }`, where `since` is when missed opened.
- It answers missed alone. Failed, stuck, slow and over budget stay open until a successful run closes them, and that run's recovery names them but not missed again.
- Channels treat it like any recovery (Twilio, Honeybadger and Bugsnag send it only with `recovered: true`).
- While the job is silenced, missed closes without a message.

## expect rules

`expect` turns a quiet success into a failure when the job produced no evidence of doing its work. The output is whatever the job logged with `job.log()`, or the string the function returned if it logged nothing. The rule sees all of it, or for very long output its first and last 16 KB, so a line logged early still counts even though only the tail is stored.

```ts
cw.job("export", { expect: "wrote" });                       // output must contain the string
cw.job("export", { expect: /wrote \d+ files/ });             // or match the pattern
cw.job("export", { expect: (out) => out.split("\n").length > 3 });   // or pass a function
```

Every port takes the same three forms in its own language: a string, a pattern (a Ruby `Regexp`, a Python `re.Pattern`, and so on) or a function. Elixir's pattern is `{:matches, "source", "flags"}`, a JavaScript pattern run by the package's own engine, since an Elixir `Regex` reads a pattern differently; Java's is `expectMatch("source", "flags")`, for the same reason, where a `java.util.regex.Pattern` would read it differently; and .NET's is `Expect.Matches("source", "flags")`, since a .NET `Regex` does too. Each language's page has the spelling.

A pattern runs in your own process, on the platform's engine, and like an `expect` function it has no time limit in Node or Python. Most engines backtrack, so a pattern with several unbounded repeats that can match the same text (`/\n*\n*\n*x/`, `/(a+)+b/`, or even `/.*x/`) can take seconds or longer on an output that almost matches but does not. Anchor a pattern where you can, avoid a repeat next to or inside another over the same characters, and prefer a plain string when a substring will do. The other ports bound it where their engine allows, and a pattern that runs out of its bound counts as not matching, so the run fails with the usual `Output did not match` message: Ruby gives each match a one second timeout, PHP stops at PCRE's backtrack limit (`pcre.backtrack_limit`) and adds its reason, `(Backtrack limit exhausted)`, Rust stops a pattern it reads back from another process's stored definition after fifty million steps, Elixir stops any pattern after ten million, and Java and .NET stop a stored pattern after fifty million. Go's `regexp` and Rust's `regex` crate run in linear time and need no bound.

## Baselines

Baselines use the last twenty successful runs, reading past any failures in between, and need at least five. Before that, only explicit limits apply. A job's history is its own: a slow job is compared to itself.

## Silence

`cw.silence(name, "2h")` (every port has the same call in its own spelling, such as `silence(name, for: "2h")` in Ruby), the dashboard button, or the MCP tool. While silenced, nothing new is recorded as an incident and no alerts are sent; conditions that clear during the silence do clear. When the silence ends, the next problem alerts normally.

## Output and metrics

Output, whether logged or returned, and errors are capped at 16 KB per run, keeping the tail. Before either is stored, values that look like secrets are replaced with `[redacted]`: `password=`, `api_key:`, `:secret => "..."` and similar pairs (quoted values in full), credentials in URLs, `Bearer`, `Basic` and `Token` authorization values, PEM private keys, JWTs, Slack and Discord webhook URLs, and AWS, GitHub, Slack, Stripe, Google and API key formats. NUL bytes are removed. `expect` rules see the output before redaction. Pass `redact` to `cronwatch()` to use your own function, or `false` to turn it off. Every port blanks the same patterns by default and has the same option in its own spelling (`redact:` in Ruby, `WithRedact` in Go, and so on). Metrics are numbers keyed by name; report as many as you like. Both are stored with the run, shown on the dashboard and in alerts, and handed to the MCP server and to triage.

## Runs that span calls

A run is normally one call to `run()`. Work that starts in one call and ends in another (the steps of an Inngest function, a queue that hands work to another process, a webhook that reports completion later) can be one run too: `job.start()` records it as running, and `finish()` on the handle it returns, or on one from `job.resume(runId)` in another process, ends it.

```ts
const run = await job.start({ id: event.id });      // records a running run
// later, perhaps elsewhere
const same = await job.resume(event.id);
same.log("sent 40 emails");
await same.finish();                                  // or same.fail(error)
```

Starting closes missed and stuck like any run starting. Finishing is judged like any run finishing: `expect`, failures, duration from the start, budgets. It opens nothing a finished `run()` would not. A run that is never finished is marked stuck after the job's `timeout`, so set `timeout` to cover the whole span, waits included. See [the run handle](/docs/api/#the-run-handle).

A run is judged once, however many times it is finished. The finish is written only while the stored run is still running (or marked timed out by a check), in one step, so when two processes finish the same run at once (a queue that delivers the completion twice, say) one records it and counts it, and the other gets `null` and hears through `onError` that the run was already finished. The built-in stores do this; a custom store without `updateRunIf` falls back to a read then a write, which is only safe when one process finishes a given run. A finish that arrives after a check marked the run stuck is still recorded: a success closes stuck with a recovery, and a failure is not counted a second time.

- `expect` sees what `run()` would: the handle keeps the first 16 KB of everything logged through it, so a line logged early still matches after `flush()` has sent it on and the stored output kept only the tail.
- A run belongs to the job that started it. `start({ id })` with an id another job holds throws, whether that job's start is still in flight or long done, and a handle that finds another job's run under its id finishes and flushes nothing. Ids starting with `pgcron:` are the [pg_cron reader's](/docs/supabase/) and are refused.
- When the store fails during `finish()`, nothing is recorded, the error goes to `onError`, and the handle stays active: call `finish()` again once the store is back. The lines and metrics logged are kept.
