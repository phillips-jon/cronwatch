---
title: Drupal
description: The CronWatch module for Drupal: every cron run and each module's hook_cron recorded with no code, queue workers that opt in, drush cronwatch:check, the store in the site's database and the dashboard under Reports.
order: 3.273
---

# Drupal

The CronWatch module records every cron run and each module's `hook_cron` in it, in the site's own database, and tells you when cron is missed, when a `hook_cron` fails, gets stuck or runs much slower than usual, and again when it recovers. Queue workers you choose are watched too, each item a run. It needs no code, and it is the Drupal module of the PHP library, [`cronwatch/cronwatch`](/docs/php/), with the same rules, alert text and stored rows. It needs Drupal 10.3 or newer or Drupal 11 (tested on 10.6 and 11.4), PHP 8.2 or newer (Drupal 11 needs 8.3), and Drush 13 for the command.

## Install

```bash
composer require drupal/cronwatch
drush pm:install cronwatch
```

Installing makes three tables in the site's database (`cronwatch_jobs`, `cronwatch_runs` and `cronwatch_state`, after the site's table prefix) with the library's own `CREATE` statements; uninstalling drops them. The database is MySQL 8.0.13 or newer, MariaDB 10.6 or newer, Postgres or SQLite; the module refuses another driver at install, with a message.

Then, under Configuration, System, CronWatch, say where alerts go and send a test alert.

## What is watched

Drupal runs every module's `hook_cron` from its cron service, whatever starts it: Automated Cron after a page, `drush cron`, or a system cron requesting `/cron/<key>`. The module records:

- **`drupal:cron`**: the whole cron run, with the trigger `"cron"`. Its output lists the modules that ran and those that failed. A run that finds cron already locked by another records nothing.
- **`drupal:<module>`**: each module's `hook_cron` in it, with what it logged and the exception it threw. Drupal carries on past a module's exception, so that module's run fails and the others and the cron run do not; an `\Error` fails both the module's run and the cron run, which Drupal lets it end.

Only `drupal:cron` has a schedule, since every `hook_cron` runs on every cron run: giving each module the site's schedule would turn a cron that stopped into one missed alert per module. The schedule is the one under the settings (what your crontab does: `*/15 * * * *`, or `every 1h`), else Automated Cron's interval (`every 3h` by default, since Automated Cron runs cron after the first request once the interval has passed), else none; the settings page says which. The module jobs report failures, slow runs and stuck runs. All are tagged `drupal-cron`. A module uninstalled keeps its history and is never reported missed.

A module's code can log to its run and record numbers:

```php
function mymodule_cron(): void {
  $count = \Drupal::service('mymodule.importer')->import();
  \Cronwatch\Cronwatch::current()?->log('Imported', $count, 'items');
  \Cronwatch\Cronwatch::current()?->metric('items', $count);
}
```

A site whose cron service another module replaced (Ultimate Cron, which runs each job on a schedule of its own) is left alone, and the settings page says CronWatch cannot record cron there. The Scheduler module's publishing runs in its `hook_cron`, so it is watched as `drupal:scheduler` like any other.

## Options per job

`hook_cronwatch_job_options_alter()` changes any job's options before it is declared:

```php
/**
 * Implements hook_cronwatch_job_options_alter().
 */
function mymodule_cronwatch_job_options_alter(array &$options, string $name, array $context): void {
  if ($name === 'drupal:search') {
    // Indexing a large site takes a while.
    $options['timeout'] = '2h';
  }
}
```

The options are the library's (`schedule`, `grace`, `timeout`, `maxDuration`, `budget`, `expect`, `failuresBeforeAlert`, `description`, `tags`; see [PHP](/docs/php/#api)); `$context` says what the job is (`kind` is `cron`, `module` or `queue`, with `module` or `queue`).

## Queues

Queue workers run in cron (those whose definition has a `cron` time) or from `drush queue:run`. Choose workers under the settings, or mark a worker class with the attribute (its options, `name` included; `enabled: false` leaves it out):

```php
use Cronwatch\Watch;
use Drupal\Core\Queue\Attribute\QueueWorker;
use Drupal\Core\Queue\QueueWorkerBase;
use Drupal\Core\StringTranslation\TranslatableMarkup;

#[QueueWorker(id: 'mymodule_sync', title: new TranslatableMarkup('Sync'), cron: ['time' => 60])]
#[Watch(grace: '30m', failuresBeforeAlert: 3)]
final class SyncWorker extends QueueWorkerBase { /* ... */ }
```

Every item the worker processes is then a run of `drupal:queue:<worker>`, with the trigger `"queue"`, in cron, Drush or anywhere else. What the worker throws, a failure or a `RequeueException`, `DelayedRequeueException` or `SuspendQueueException` asking for the item back, is recorded as a failed attempt and thrown on, so Drupal releases, delays or keeps the item as it would. Failing attempts open one alert and the attempt that succeeds closes it with a recovery. Workers are tagged `drupal-queue`; one no longer watched keeps its history without a schedule.

## The check

Missed and stuck runs are found by a check. It runs at the end of every cron run (untick "Run the check at the end of each cron run" to stop that), and from Drush:

```bash
drush cronwatch:check
```

which declares every job, finds missed and stuck runs, sends their alerts, retries alerts no channel accepted and prunes old runs, and prints `cronwatch: checked 12 jobs, sent 0 alerts`; an error is a non-zero exit.

A check that runs at the end of cron cannot notice cron not running: when nothing starts cron (a quiet site on Automated Cron, a crontab line that broke), nothing starts the check either. So run the check from the server's crontab too, separately from cron, and prefer a system cron to Automated Cron for anything that must run on time:

```
*/5 * * * *  cd /var/www/site && vendor/bin/drush cron --quiet
*/5 * * * *  cd /var/www/site && vendor/bin/drush cronwatch:check --quiet
```

and set the cron schedule under the settings to match (`*/5 * * * *`). A missed `drupal:cron` is how a site learns it needs one. Run one checker per store.

## The store

The tables are in the site's own database, read from `settings.php` (`$databases['default']['default']`, or the key `$settings['cronwatch_database']` names), through a connection of CronWatch's own with the same host, credentials and SSL options, so a run recorded inside Drupal's transaction stays recorded when the transaction rolls back. On SQLite the file is put in WAL mode, which Drupal's own connection works with.

## Settings

Configuration, System, CronWatch (`/admin/config/system/cronwatch`), for users with "Administer CronWatch":

- **Email alerts to**: sent through the site's mail system, with the library's subject and text.
- **Slack incoming webhook URL**, **Webhook URL** and **Webhook signing secret**: the library's channels; the webhook is signed with the secret in `X-CronWatch-Signature` when there is one.
- **Cron schedule** and **Grace** (10 minutes by default).
- **Run the check at the end of each cron run**, and the **Watched queues**.

"Send a test alert" sends one to every channel the saved settings name and says what each answered, including a partial failure (one address of several refused, say). Nothing leaves the site until a channel is set; with none, alerts go to the site's log (the `cronwatch` channel), as do failures outside jobs, and the test alert sends nothing: it warns that no channel is set and asks you to save one first. `hook_cronwatch_alerts_alter()` adds channels, any of the library's ([PHP](/docs/php/#email-sms-and-error-trackers)) or a callable taking the `Cronwatch\Alert`:

```php
function mymodule_cronwatch_alerts_alter(array &$channels): void {
  $channels[] = new \Cronwatch\Alerts\Discord(getenv('DISCORD_WEBHOOK_URL'));
}
```

The settings are configuration, exported with the site's; keep a credential out of the export by setting it in `settings.php`:

```php
$config['cronwatch.settings']['slack_webhook_url'] = getenv('SLACK_WEBHOOK_URL');
```

## The dashboard

Reports, CronWatch (`/admin/reports/cronwatch`), for users with "View the CronWatch dashboard": the jobs' health, the last 24 hours as a lane per job, each job's week, runs and output. These are the library's pages ([Dashboard and API](/docs/dashboard/)), shown within the admin theme with Drupal's sign-in standing for the dashboard's token. Silencing, forgetting and "Run check now" need "Administer CronWatch" as well, and carry Drupal's CSRF token. Both permissions are restricted: grant them to trusted roles only, since run output holds what each job logged.

The JSON API that [`@cronwatch/mcp`](/docs/mcp/) talks to is off (404) until a token is set, in `settings.php` or the environment:

```php
$settings['cronwatch_token'] = getenv('CRONWATCH_TOKEN');
```

It is then at `/cronwatch/api`, answering requests that carry the token as a bearer:

```bash
claude mcp add cronwatch -e CRONWATCH_URL=https://example.com/cronwatch -e CRONWATCH_TOKEN=... -- npx -y @cronwatch/mcp
```

## Tests

The module records through the site's database, so a test site records its cron runs like any other: run `drush cron` and `drush cronwatch:check` in a functional test, and assert on the runs through the client the module uses, `\Drupal::service('cronwatch.recorder')->client()` (`->runs('drupal:mymodule')`). The same client declares and runs a job of your own (`->job('nightly-export', [...])->run(...)`); see [PHP](/docs/php/#declare-and-run-a-job).
