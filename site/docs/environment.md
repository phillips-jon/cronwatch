---
title: Environment variables
description: Every environment variable each CronWatch library reads, by language and integration, with what it does and what happens when it is not set.
order: 13.5
group: Reference
---

# Environment variables

Every CronWatch library reads a handful of environment variables, so the dashboard's token and the cron secret can stay out of your code. Their names are part of the [1.x promise](/docs/stability/#configuration-and-environment-variables). An option passed in code always wins over the variable, and a variable set to an empty string, or only spaces, counts as not set. For the dashboard's token and the cron secret, "only spaces" means only whitespace, as JavaScript's `trim` reads it, and an option given in code that is empty or only whitespace counts as not given too; a token or secret given in code must be a string, or null to opt out, and any other value (`false`, a number) is refused with an error rather than turned into a password.

## The ones every library reads

| Variable | What it does | When it is not set |
|---|---|---|
| `CRONWATCH_TOKEN` | the dashboard's and the JSON API's token, when none is passed | the dashboard answers 503, or in development makes a token of its own and prints it to the log ([Access](/docs/dashboard/#access)) |
| `CRON_SECRET` | the bearer secret a job's handler and `/api/check` accept, when none is passed | a handler refuses with 503, except in development, where it runs; `/api/check` takes only the token |
| `CRONWATCH_ENV`, then `APP_ENV` | names the environment, before the language's own variable (below) | the language's own variable or framework decides |
| `ANTHROPIC_API_KEY` | the API key for [Claude triage](/docs/triage/), when none is passed | triage cannot run; TypeScript, Ruby and Python leave the variable to Anthropic's own SDK, which reads it |

`@cronwatch/mcp` reads two: `CRONWATCH_URL`, where the dashboard is mounted (the `--url` flag wins; with neither it exits), and `CRONWATCH_TOKEN`, the bearer it sends (the `--token` flag wins; without one it works only against an open dashboard, and says so). See [MCP server](/docs/mcp/).

## Development and production

Development decides two things: a dashboard with no token makes one of its own and prints it, and a handler with no secret runs. Production decides one: the default in-memory store warns that it forgets on restart. Every library names the environment the same way:

1. Take the first variable in the language's order (below) whose value, trimmed, is not empty, and lowercase it.
2. `prod` means production. `dev`, `local`, `test` and `testing` mean development, as `development` does.
3. With nothing set, the environment is neither, so there is no development token and no unguarded handler.

| Language | Order |
|---|---|
| TypeScript | `CRONWATCH_ENV`, `APP_ENV`, `NODE_ENV`. A Cloudflare Worker without `process` has none, and is neither |
| Ruby | `CRONWATCH_ENV`, `APP_ENV`, then `Rails.env` when Rails is loaded, `RAILS_ENV`, `RACK_ENV`. `RACK_ENV=development` alone does not count while Puma, Unicorn, Thin or rackup is loaded, since they set it by default |
| Python | `CRONWATCH_ENV`, `APP_ENV`, `ENVIRONMENT`, then under Django its `DEBUG` setting (on is development, off is production) |
| PHP | `CRONWATCH_ENV`, `APP_ENV`, `WP_ENVIRONMENT_TYPE`, then the framework's own: WordPress's `wp_get_environment_type()`, Laravel's `app()->environment()`, Symfony's `kernel.environment` |
| Go | `CRONWATCH_ENV`, `APP_ENV`, `GO_ENV` |
| Rust | `CRONWATCH_ENV`, `APP_ENV`, `RUST_ENV`. A debug build is not development by itself |
| Elixir | `CRONWATCH_ENV`, `APP_ENV`, `MIX_ENV`, read at run time, so a release without `MIX_ENV` is neither |
| Java | `CRONWATCH_ENV`, `APP_ENV`, then the builder's `environment(name)`; the Spring Boot starter passes the first active profile that names development or production, else the first active profile |
| .NET | `CRONWATCH_ENV`, `APP_ENV`, then `CronwatchOptions.Environment` (under `AddCronwatch`, the `Cronwatch:Environment` setting, else the host's environment name), then `ASPNETCORE_ENVIRONMENT`, `DOTNET_ENVIRONMENT` |

## By language

Besides the ones above, each library reads these.

### TypeScript

| Variable | What it does | When it is not set |
|---|---|---|
| `DATABASE_URL` | the Postgres store's connection string, when neither `connectionString` nor `pool` is passed | `pg`'s own defaults (its `PG*` variables) |

### Ruby

| Variable | What it does | When it is not set |
|---|---|---|
| `SOLID_QUEUE_RECURRING_SCHEDULE` | the Solid Queue recurring schedule file the integration reads, as Solid Queue does | `config/recurring.yml` |
| `SOLID_QUEUE_SKIP_RECURRING` | set (and not a false value), no recurring tasks are read, as Solid Queue does | they are read |

The Rails install generator writes an initializer that reads `SLACK_WEBHOOK_URL`, with `DISCORD_WEBHOOK_URL`, `CRONWATCH_WEBHOOK_URL` and `CRONWATCH_WEBHOOK_SECRET` in comments. That code is yours to change; the gem itself does not read them.

### Python

| Variable | What it does | When it is not set |
|---|---|---|
| `DATABASE_URL` | the Postgres store's connection string, when none is passed | libpq's own defaults (its `PG*` variables) |
| `TZ` | the zone of a Celery beat schedule, only when Celery's `timezone` setting is unset and `enable_utc` is off (with Celery's defaults a schedule is read in UTC, and a django-celery-beat schedule carries its own zone) | the system's zone (`/etc/localtime`) in that case |

Django reads no variable of its own: its settings go in the `CRONWATCH` dict in `settings.py` (`TOKEN` first, then `CRONWATCH_TOKEN`). See [Django](/docs/django/).

### PHP

Variables are read from `getenv()`, then `$_ENV`, then `$_SERVER`.

| Variable | What it does | When it is not set |
|---|---|---|
| `DATABASE_URL` | the Postgres store's URL when it starts with `postgres://` or `postgresql://`, and the MySQL store's when it starts with `mysql://` or `mariadb://`; also the Symfony bundle's store when `store` is not set | the store needs its connection passed |
| `ANTHROPIC_BASE_URL` | the API triage posts to | `https://api.anthropic.com` |
| `CRONWATCH_BOOTSTRAP` | the bootstrap file the `cronwatch` command (`vendor/bin/cronwatch`) loads (`--bootstrap` wins) | `./cronwatch.php`, then `./config/cronwatch.php` |

`cronSecret`, the dashboard's `token` and a handler's `secret` read `CRON_SECRET` and `CRONWATCH_TOKEN` when left out (or given `Cronwatch\FromEnv::Read`); `null` turns them off. The integrations:

- **Laravel** reads its settings from `config/cronwatch.php`, whose values come from the variables in the table below.
- **Symfony** has no variables of its own: write `%env(...)%` in `config/packages/cronwatch.yaml`. Left unset, `cron_secret` reads `CRON_SECRET`, `dashboard.token` reads `CRONWATCH_TOKEN`, and `store` uses `DATABASE_URL`, else `var/cronwatch.db`.
- **WordPress** reads only `WP_ENVIRONMENT_TYPE`; its token and channels are the plugin's settings, and it has no cron secret.
- **Drupal** uses the `cronwatch_token` setting, else `CRONWATCH_TOKEN`, and reads `CRON_SECRET`.
- **Craft CMS** uses the `apiToken` setting, else `CRONWATCH_TOKEN`, and reads `CRON_SECRET`; any setting written as `$NAME` is read from that variable, as Craft does.

Laravel's variables, each filling one key of `config/cronwatch.php`:

| Variable | Key | Default |
|---|---|---|
| `CRONWATCH_ENABLED` | `enabled` | `true` |
| `CRONWATCH_APP_ID` | `app_id` | the app's name (`app.name`) |
| `CRONWATCH_STORE` | `store.driver` | `database` (or `sqlite`, `memory`) |
| `CRONWATCH_DB_CONNECTION` | `store.connection` | the app's default connection |
| `CRONWATCH_SQLITE_PATH` | `store.path` | none |
| `CRONWATCH_MIGRATIONS` | `store.migrations` | `true` |
| `CRONWATCH_TABLE_PREFIX` | `table_prefix` | `cronwatch_` |
| `CRONWATCH_CREATE_TABLES` | `create_tables` | `true` |
| `CRONWATCH_MAIL_TO` | `alerts.mail.to` | none |
| `CRONWATCH_MAIL_FROM` | `alerts.mail.from` | none |
| `CRONWATCH_MAILER` | `alerts.mail.mailer` | none |
| `CRONWATCH_MAIL_SUBJECT_PREFIX` | `alerts.mail.subject_prefix` | none |
| `CRONWATCH_SLACK_WEBHOOK_URL` | `alerts.slack` | none |
| `CRONWATCH_DISCORD_WEBHOOK_URL` | `alerts.discord` | none |
| `CRONWATCH_WEBHOOK_URL` | `alerts.webhook.url` | none |
| `CRONWATCH_WEBHOOK_SECRET` | `alerts.webhook.secret` | none |
| `CRONWATCH_LOG_CHANNEL` | `alerts.log` | none |
| `CRONWATCH_TRIAGE` | `triage.enabled` | `false` (on, it reads `ANTHROPIC_API_KEY`) |
| `CRONWATCH_TRIAGE_MODEL` | `triage.model` | the library's default |
| `CRONWATCH_TRIAGE_CONTEXT` | `triage.context` | none |
| `CRON_SECRET` | `cron_secret` | none |
| `CRONWATCH_RETENTION` | `retention` | `30d` |
| `CRONWATCH_DELIVER` | `deliver` | `now` |
| `CRONWATCH_WATCH_SCHEDULE` | `schedule.watch` | `true` |
| `CRONWATCH_CAPTURE_OUTPUT` | `schedule.capture_output` | `false` |
| `CRONWATCH_SCHEDULE_CHECK` | `check.schedule` | `true` |
| `CRONWATCH_CHECK_CRON` | `check.frequency` | `*/5 * * * *` |
| `CRONWATCH_WATCH_QUEUE` | `queue.watch` | `true` |
| `CRONWATCH_DASHBOARD` | `dashboard.enabled` | `true` |
| `CRONWATCH_PATH` | `dashboard.path` | `cronwatch` |
| `CRONWATCH_DOMAIN` | `dashboard.domain` | none |
| `CRONWATCH_TOKEN` | `dashboard.token` | none |

See [Laravel](/docs/laravel/#settings) for what each key does.

### Go

| Variable | What it does | When it is not set |
|---|---|---|
| `CRONWATCH_APP_ID` | the app the scheduler integrations (robfig/cron, gocron, River, Asynq) tag their jobs with, when `Options.App` is not set | the executable's name |
| `ANTHROPIC_BASE_URL` | the API triage posts to | `https://api.anthropic.com` |
| `TZ` | the zone of a scheduler entry that names none | the system's zone; set but empty, UTC |
| `ZONEINFO` | a further zone database to list zones from, as Go's own `time` package reads it | Go's defaults |

`sqlstore` reads no `DATABASE_URL`: open the `*sql.DB` yourself.

### Rust

| Variable | What it does | When it is not set |
|---|---|---|
| `CRONWATCH_APP_ID` | the app the scheduler integrations (tokio-cron-scheduler, apalis) tag their jobs with, when `Options::app` is not set | the executable's file name |
| `ANTHROPIC_BASE_URL` | the API triage posts to (the `triage` feature) | `https://api.anthropic.com` |
| `TZ` | the system zone, through jiff, for a schedule that names none | `/etc/localtime` |

`cronwatch-sqlx` reads no variable: pass it your pool.

### Elixir

| Variable | What it does | When it is not set |
|---|---|---|
| `CRONWATCH_APP_ID` | the app the Oban and Quantum integrations tag their jobs with, when `app:` is not given | the OTP application that started the instance |
| `ANTHROPIC_BASE_URL` | the API triage posts to | `https://api.anthropic.com` |
| `TZ` | the local zone, for a schedule that names none (a leading `:` is dropped) | `/etc/localtime`, else UTC |

`CRON_SECRET` and `CRONWATCH_TOKEN` are read on each request, so a release picks up a changed value without a restart. `token: {:system, "NAME"}` and a handler's `secret: {:system, "NAME"}` read a variable of your choosing first. `cron_secret: false` turns the secret off.

### Java

| Variable | What it does | When it is not set |
|---|---|---|
| `CRONWATCH_APP_ID` | the app the scheduler integrations tag their jobs with, when their `app` option (`cronwatch.app` in the starter) is not set | `spring.application.name` in the starter, else the main class's name or the jar's |
| `ANTHROPIC_BASE_URL` | the API triage posts to | `https://api.anthropic.com` |

A schedule with no zone is read in the JVM's default zone, which follows `TZ` and `-Duser.timezone`. The Spring Boot starter's settings are the `cronwatch.*` and `cronwatch.web.*` properties, which Spring Boot also reads from variables by its relaxed binding: `CRONWATCH_WEB_TOKEN` sets `cronwatch.web.token`. Left unset, `cronwatch.cron-secret` reads `CRON_SECRET` and `cronwatch.web.token` reads `CRONWATCH_TOKEN`. See [Java schedulers](/docs/java-schedulers/).

### .NET

| Variable | What it does | When it is not set |
|---|---|---|
| `CRONWATCH_APP_ID` | the app the Hangfire and Quartz.NET integrations tag their jobs with, when their `App` option is not set | the host's application name (Quartz.NET), else the entry assembly's name |
| `ANTHROPIC_BASE_URL` | the API triage posts to | `https://api.anthropic.com` |
| `ASPNETCORE_ENVIRONMENT`, `DOTNET_ENVIRONMENT` | the environment, after `CRONWATCH_ENV`, `APP_ENV` and the host's own (above) | |

`Cronwatch.Hosting` reads the `Cronwatch` configuration section (`Retention`, `Token`, `CheckEvery`, `Environment`), which the default host also fills from variables such as `Cronwatch__Token`. A schedule with no zone is read in `TimeZoneInfo.Local`, which follows `TZ` on Linux and macOS. See [.NET](/docs/dotnet/).
