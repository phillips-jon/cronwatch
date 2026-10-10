---
title: Drupal
description: The CronWatch module for Drupal: every cron run and each module's hook_cron recorded with no code, queue workers that opt in, drush cronwatch:check, the store in the site's database, and the dashboard under Reports.
order: 3.74
group: PHP
---

# Drupal

The CronWatch module records every cron run and each module's `hook_cron` in it, in the site's own database, and tells you when cron is missed, when a `hook_cron` fails, gets stuck, or runs much slower than usual, and again when it recovers. Queue workers you choose are watched too, each item a run. It needs no code, and it is the Drupal module of the PHP library, [`cronwatch/cronwatch`](/docs/php/), with the same rules, alert text, and stored rows. It needs Drupal 10.3 or newer or Drupal 11 (tested on 10.6 and 11.4), PHP 8.2 or newer (Drupal 11 needs 8.3), and Drush 13 for the command.

## Install

```bash
composer require drupal/cronwatch
drush pm:install cronwatch
```

The module's page on drupal.org is [drupal.org/project/cronwatch](https://www.drupal.org/project/cronwatch). Installing makes three tables in the site's database (`cronwatch_jobs`, `cronwatch_runs`, and `cronwatch_state`, after the site's table prefix) with the library's own `CREATE` statements; uninstalling drops them. The database is MySQL 8.0.13 or newer, MariaDB 10.6 or newer, Postgres, or SQLite; the module refuses another driver at install, with a message.

Then, under Configuration, System, CronWatch, say where alerts go and send a test alert.

## What is watched

Drupal runs every module's `hook_cron` from its cron service, whatever starts it: Automated Cron after a page, `drush cron`, or a system cron requesting `/cron/<key>`. The module records:

- **`drupal:cron`**: the whole cron run, with the trigger `"drupal-cron"` (`"cron"` on runs recorded before 0.11; see [Triggers, tags, and job names](/docs/dashboard/#triggers-tags-and-job-names)). Its output lists the modules that ran and those that failed. A run that finds cron already locked by another records nothing.
- **`drupal:<module>`**: each module's `hook_cron` in it, with what it logged and the exception it threw. Drupal carries on past a module's exception, so that module's run fails and the others and the cron run do not; an `\Error` fails both the module's run and the cron run, which Drupal lets it end. A module with more than one `hook_cron` (Drupal 11.1 and newer, `#[Hook('cron')]` on several methods) is one run, failed if any of them threw.

Only `drupal:cron` has a schedule, since every `hook_cron` runs on every cron run: giving each module the site's schedule would turn a cron that stopped into one missed alert per module. The schedule is the one under the settings (what your crontab does: `*/15 * * * *`, or `every 1h`), else Automated Cron's interval (`every 3h` by default, since Automated Cron runs cron after the first request once the interval has passed), else none; the settings page says which. The module jobs report failures, slow runs, and stuck runs. All are tagged `drupal-cron`. The `drupal:` prefix keeps a module's job apart from the app's own jobs of the same name. A module uninstalled keeps its history and is never reported missed.

A module's code can log to its run and record numbers:

```php
function mymodule_cron(): void {
  $count = \Drupal::service('mymodule.importer')->import();
  \Cronwatch\Cronwatch::current()?->log('Imported', $count, 'items');
  \Cronwatch\Cronwatch::current()?->metric('items', $count);
}
```

A site running Ultimate Cron is watched too, each of its jobs on its own schedule (see [Ultimate Cron](#ultimate-cron)). A site whose cron service another module replaced is left alone, and the settings page says CronWatch cannot record cron there. The Scheduler module's publishing runs in its `hook_cron`, so it is watched as `drupal:scheduler` like any other.

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

The options are the library's (`schedule`, `grace`, `timeout`, `maxDuration`, `budget`, `floor`, `expect`, `failuresBeforeAlert`, `description`, `tags`; see [PHP](/docs/php/#api)); `$context` says what the job is (`kind` is `cron`, `module`, `queue`, or `ultimate_cron`, with `module`, `queue`, or `job` and `module`).

## Ultimate Cron

[Ultimate Cron](https://www.drupal.org/project/ultimate_cron) (2.0.0-beta1 and newer) replaces Drupal's cron service with its own, which runs each of its jobs (one per module's `hook_cron`, and any a site adds) when its own rules say, each under a lock of its own. CronWatch records them with no code:

- **Each job's runs.** Every run of an Ultimate Cron job is a run of its job: `drupal:<module>` for a module's `hook_cron`, the same job as without Ultimate Cron, so its history goes on; `drupal:job:<id>` for any other job. The trigger is `"ultimate-cron"` for a run a cron run launched, and `"ultimate-cron-manual"` for one launched on its own, from the job's "Run" button or `drush cron:run <job>`. What the job logs through `Cronwatch::current()` is its output, and what it throws, an exception or an `\Error`, fails the run; Ultimate Cron still catches it and logs it as before.
- **Each job's schedule.** A job is expected on its own rules, read as Ultimate Cron reads them, in the site's time zone. Ultimate Cron's `@` (a skew from 0 to 255 fixed per job, which spreads jobs across the hour) and `+N` (an offset) are worked out to the minutes they name, so `*/15+@ * * * *` for a job whose skew is 7 is `7,22,37,52 * * * *`. The Simple scheduler's intervals are such rules too. A job whose rules no cron expression can say (several rules naming different times, a scheduler plugin of another module, a rule that never matches) is watched without a schedule, and the site's log says why, once; a disabled job has no schedule, since Ultimate Cron does not run it.
- **Cron itself.** Every cron run is still a run of `drupal:cron`, with the trigger `"drupal-cron"` and the jobs it launched (and those that failed) as its output, on the schedule under the settings, else Automated Cron's interval, as without Ultimate Cron. The check runs after it as before.
- **Skipped jobs.** A job Ultimate Cron skips because it is locked or still running is no run; the one still running is recorded already, and is reported stuck if it never ends.

Ultimate Cron runs a job at the first cron run after its time, so a job is only on time when cron runs at least as often as the job: run cron every minute from the server's crontab, as Ultimate Cron asks, or a job every 15 minutes on a cron every 3 hours is reported missed, as it is.

```
* * * * *    cd /var/www/site && vendor/bin/drush cron --quiet
*/5 * * * *  cd /var/www/site && vendor/bin/drush cronwatch:check --quiet
```

With Ultimate Cron's queue handling on, each queue is a job of its own (`drupal:job:ultimate_cron_queue_<worker>`), and the items of a watched worker are still runs of `drupal:queue:<worker>`. Uninstall Ultimate Cron and Drupal's cron is recorded as before: the modules' jobs go on without a schedule, and the other jobs keep their history and are never reported missed.

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

Every item the worker processes is then a run of `drupal:queue:<worker>`, with the trigger `"drupal-queue"` (`"queue"` on runs recorded before 0.11), in cron, Drush, or anywhere else. What the worker throws, a failure or a `RequeueException`, `DelayedRequeueException`, or `SuspendQueueException` asking for the item back, is recorded as a failed attempt and thrown on, so Drupal releases, delays, or keeps the item as it would. Failing attempts open one alert and the attempt that succeeds closes it with a recovery. Workers are tagged `drupal-queue`; one no longer watched keeps its history without a schedule.

## The check

Missed and stuck runs are found by a check. It runs at the end of every cron run (untick "Run the check at the end of each cron run" to stop that), and from Drush:

```bash
drush cronwatch:check
```

which declares every job, finds missed and stuck runs, sends their alerts, retries alerts no channel accepted, prunes old runs, and prints `cronwatch: checked 12 jobs, sent 0 alerts`; an error is a non-zero exit.

A check that runs at the end of cron cannot notice cron not running: when nothing starts cron (a quiet site on Automated Cron, a crontab line that broke), nothing starts the check either. So run the check from the server's crontab too, separately from cron, and prefer a system cron to Automated Cron for anything that must run on time:

```
*/5 * * * *  cd /var/www/site && vendor/bin/drush cron --quiet
*/5 * * * *  cd /var/www/site && vendor/bin/drush cronwatch:check --quiet
```

and set the cron schedule under the settings to match (`*/5 * * * *`). A missed `drupal:cron` is how a site learns it needs one. Run one checker per store.

## The store

The tables are in the site's own database, read from `settings.php` (`$databases['default']['default']`, or the key `$settings['cronwatch_database']` names), through a connection of CronWatch's own with the same host, credentials, and SSL options, so a run recorded inside Drupal's transaction stays recorded when the transaction rolls back. On SQLite the file is put in WAL mode, which Drupal's own connection works with.

## Settings

Configuration, System, CronWatch (`/admin/config/system/cronwatch`), for users with "Administer CronWatch":

- **Email alerts to**: sent through the site's mail system, with the library's subject and text.
- **Slack incoming webhook URL**, **Webhook URL**, and **Webhook signing secret**: the library's channels; the webhook is signed with the secret in `X-CronWatch-Signature` when there is one.
- **More channels**, each folded under its name until one of its fields is set: Discord; email through Resend, Postmark, SendGrid, Mailgun, or Amazon SES, for a site whose own mail is not reliable; text messages through Twilio; and the error trackers Sentry, Honeybadger, Datadog, Rollbar, Bugsnag, and New Relic. Each asks for what its provider needs (an API key, a from address on a domain the provider has verified, the addresses or numbers to send to, and the provider's options such as the region) and sends once every required field is set. A provider only partly filled in is refused beside the field it lacks. Each is a key of `cronwatch.settings` named for the provider and the field: `discord_webhook_url`, `resend_api_key`, `resend_from`, `resend_to`, `ses_region`, `twilio_account_sid`, `newrelic_license_key`.
- **Cron schedule** and **Grace** (10 minutes by default).
- **Run the check at the end of each cron run**, and the **Watched queues**.

"Send a test alert" sends one to every channel the saved settings name and says what each answered, including a partial failure (one address of several refused, say). Nothing leaves the site until a channel is set; with none, alerts go to the site's log (the `cronwatch` channel), as do failures outside jobs, and the test alert sends nothing: it warns that no channel is set and asks you to save one first. `hook_cronwatch_alerts_alter()` adds channels beyond the settings', any of the library's with options the form does not offer ([PHP](/docs/php/#email-sms-and-error-trackers)) or a callable taking the `Cronwatch\Alert`:

```php
function mymodule_cronwatch_alerts_alter(array &$channels): void {
  $channels[] = new \Cronwatch\Alerts\Discord(getenv('DISCORD_WEBHOOK_URL'));
}
```

The links in alerts go to the job's page on the dashboard, at the site's address. Set it in `settings.php` (with the subdirectory when the site is in one):

```php
$settings['cronwatch_base_url'] = 'https://example.com';
```

Without it, the address is that of the request cron ran in, but only where Drupal has checked its host (`trusted_host_patterns`) or under Drush (its `--uri`). A site that trusts any host sends alerts without a link, since Automated Cron runs after a visitor's request, whose host the visitor chose.

The settings are configuration, exported with the site's; keep a credential out of the export by setting it in `settings.php`:

```php
$config['cronwatch.settings']['slack_webhook_url'] = getenv('SLACK_WEBHOOK_URL');
```

## The dashboard

Reports, CronWatch (`/admin/reports/cronwatch`), for users with "View the CronWatch dashboard": the jobs' health, the last 24 hours as a lane per job, each job's week, runs, and output. These are the library's pages ([Dashboard and API](/docs/dashboard/)), shown within the admin theme with Drupal's sign-in standing for the dashboard's token. Silencing, forgetting, and "Run check now" need "Administer CronWatch" as well, and carry Drupal's CSRF token. Both permissions are restricted: grant them to trusted roles only, since run output holds what each job logged.

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
