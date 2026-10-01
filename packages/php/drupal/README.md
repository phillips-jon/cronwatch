# CronWatch for Drupal

Cron monitoring that lives inside your Drupal site. Every cron run and each module's `hook_cron` in it is recorded in the site's own database, and you are told when cron is missed, when a `hook_cron` fails, gets stuck or runs much slower than usual, and again when it recovers. Queue workers you choose are watched too, each item a run. No server to run, no account to make.

This is the Drupal module of [the CronWatch library](https://cronwatch.dev/) (`cronwatch/cronwatch`), which also watches jobs in TypeScript, Ruby, Python, Go, Rust, Elixir, Java and .NET apps, plain PHP, Laravel, Symfony, WordPress and Craft CMS, and keeps the same tables in every language.

## Requirements

- Drupal 10.3 or newer (10.6 tested) or Drupal 11 (11.4 tested), with Drush 13 for the command.
- PHP 8.2 or newer (Drupal 11 needs 8.3).
- MySQL 8.0.13 or newer, MariaDB 10.6 or newer, Postgres, or SQLite: the site's own database.

## Install

```
composer require drupal/cronwatch
drush pm:install cronwatch
```

Installing makes three tables in the site's database (`cronwatch_jobs`, `cronwatch_runs` and `cronwatch_state`, after the site's table prefix); uninstalling drops them.

## What is watched

- **Cron.** Every cron run, whatever starts it (Automated Cron after a page, `drush cron`, a system cron requesting `/cron/<key>`), is a run of the job `drupal:cron`, and each module's `hook_cron` in it a run of `drupal:<module>`, with what it logged and the exception it threw. Drupal carries on past a module's exception, so that module's run fails and the others and the cron run itself do not.
- **The schedule.** Drupal's cron has no schedule per hook: every `hook_cron` runs on every cron run. So only `drupal:cron` has one, the site's: the one under the settings (what your crontab does, `*/15 * * * *` or `every 1h`), else Automated Cron's interval (`every 3h` by default), else none. When cron stops, that is one missed alert, not one per module.
- **Queues.** Choose queue workers under the settings, or mark a worker class `#[Cronwatch\Watch]`, and every item it processes is a run of `drupal:queue:<worker>` (in cron, `drush queue:run`, anywhere). An item that throws, or asks to be requeued, is a failed attempt; the attempt that succeeds closes the alert.

A module's code can log to its run with `Cronwatch\Cronwatch::current()?->log('...')` and record numbers with `->metric('name', 1.5)`.

## The check

Missed and stuck runs are found by a check. It runs at the end of every cron run, and from `drush cronwatch:check`, which prints `cronwatch: checked 12 jobs, sent 0 alerts`.

A check that runs at the end of cron cannot notice cron not running: when nothing starts cron (a quiet site on Automated Cron, a crontab line that broke), nothing starts the check either. So run the check from the server's crontab too, separately from cron, and prefer a system cron to Automated Cron for anything that must run on time:

```
*/5 * * * *  cd /var/www/site && vendor/bin/drush cron --quiet
*/5 * * * *  cd /var/www/site && vendor/bin/drush cronwatch:check --quiet
```

and set the schedule under the settings to match (`*/5 * * * *`). A missed `drupal:cron` is how a site learns it needs one.

## Settings

Configuration, System, CronWatch (`/admin/config/system/cronwatch`), for users with "Administer CronWatch": where alerts go (email through the site's mail system, a Slack incoming webhook, a webhook, signed when given a secret), the grace a run is given (10 minutes by default), cron's schedule, whether the check runs after each cron run, and the watched queues. "Send a test alert" sends one to every channel and says what each answered. Nothing leaves the site until a channel is set; with none, alerts go to the site's log.

The settings are configuration, so they are exported with it; keep a credential out of the export by setting it in `settings.php`:

```php
$config['cronwatch.settings']['slack_webhook_url'] = getenv('SLACK_WEBHOOK_URL');
```

`hook_cronwatch_alerts_alter()` adds channels (any of the library's, or a callable), and `hook_cronwatch_job_options_alter()` changes a job's options (a longer timeout for a slow `hook_cron`, say); see `cronwatch.api.php`.

## The dashboard

Reports, CronWatch (`/admin/reports/cronwatch`), for users with "View the CronWatch dashboard": the jobs' health, the last day as a timeline, each job's runs and output. Silencing, forgetting and "Run check now" need "Administer CronWatch" as well, and carry Drupal's CSRF token.

The JSON API that [`@cronwatch/mcp`](https://www.npmjs.com/package/@cronwatch/mcp) talks to is off until a token is set in `settings.php` (`$settings['cronwatch_token'] = '...'`, or the `CRONWATCH_TOKEN` environment variable); it is then at `https://example.com/cronwatch/api`, with the token as a bearer token.

## Settings in settings.php

- `$settings['cronwatch_database']`: the `$databases` key to keep the tables in (default `default`).
- `$settings['cronwatch_token']`: the JSON API's token.
- `$settings['cronwatch_base_url']`: the site's address for the links in alerts (`https://example.com`, with the subdirectory when the site is in one). Without it, alerts link to the address of the request that ran cron when `trusted_host_patterns` is set or under Drush, and go without a link otherwise.

## Ultimate Cron

Ultimate Cron (2.0.0-beta1 and newer) runs each of its jobs on a schedule of its own, and CronWatch records them with no code:

- **Each job.** Every run of an Ultimate Cron job is a run of its own job: `drupal:<module>` for a module's `hook_cron` (the same job as without Ultimate Cron, so its history goes on), `drupal:job:<id>` for any other. A run a cron run launched has the trigger `ultimate-cron`; one launched on its own (the job's "Run" button, `drush cron:run <job>`) has `ultimate-cron-manual`. A job that throws, an exception or an `\Error`, fails its run with what it threw, and Ultimate Cron logs it as before.
- **Its schedule.** Each job is expected on its own rules, read as Ultimate Cron reads them, the `@` skew included, in the site's time zone: `*/15+@ * * * *` for a job whose skew is 7 is `7,22,37,52 * * * *`. A job whose rules no cron expression can say (several rules at different times, another scheduler plugin) is watched without a schedule, which the site's log says once; a disabled job has none. Ultimate Cron runs a job at the first cron run after its time, so run cron at least as often as your most frequent job (every minute, as Ultimate Cron asks), or that job is reported missed.
- **Cron itself.** Every cron run is still a run of `drupal:cron`, its output the jobs it launched, on the schedule under the settings (else Automated Cron's interval).
- **Skipped jobs.** A job Ultimate Cron skips, because it is still running or locked, is no run.

The Scheduler module's publishing runs in its `hook_cron`, so it is watched as `drupal:scheduler` like any other module.

## License

GPL-2.0-or-later, as every module on drupal.org. The library it uses is MIT.
