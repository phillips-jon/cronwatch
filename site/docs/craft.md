---
title: Craft CMS
description: The CronWatch plugin for Craft CMS: the console commands your crontab runs and the queue jobs you choose, craft cronwatch/check, the store in Craft's database and the dashboard in the Control Panel.
order: 3.75
group: PHP
---

# Craft CMS

The CronWatch plugin watches the work a Craft CMS site does in the background: the console commands its crontab runs and the queue jobs you choose. Every run is recorded in the site's own database, and you are told when a run is missed, fails, gets stuck or runs much slower than usual, and again when it recovers. It is the Craft CMS plugin of the PHP library, [`cronwatch/cronwatch`](/docs/php/), with the same rules, alert text and stored rows. It needs Craft CMS 5.3 or newer, PHP 8.2 or newer, and Craft's own database (MySQL 8.0.13 or newer, MariaDB 10.6 or newer, or Postgres).

## Install

```bash
composer require cronwatch/craft
php craft plugin/install cronwatch
```

Or install it from the [Plugin Store](https://plugins.craftcms.com/cronwatch) in the Control Panel. Installing makes three tables in Craft's database (`cronwatch_jobs`, `cronwatch_runs` and `cronwatch_state`, after Craft's table prefix) with the library's own `CREATE` statements; uninstalling drops them.

## What is watched

Craft CMS has no scheduler of its own: scheduled work is console commands the server's crontab runs (`craft resave/entries`, a module's own commands) and queue jobs. Both are watched when you say so, in `config/cronwatch.php`:

```php
<?php
return [
    // Console commands the crontab runs, by route, with the schedule the crontab keeps.
    'commands' => [
        'resave/entries' => ['schedule' => '0 3 * * *', 'timezone' => 'Europe/London'],
        'app/reports/send' => ['schedule' => '*/15 * * * *', 'grace' => '5m', 'name' => 'send-reports'],
        'app/cleanup' => true,                     // runs and failures only, no schedule
    ],
    // Queue job classes, each attempt a run.
    'queueJobs' => [
        modules\jobs\SyncInventory::class => ['failuresBeforeAlert' => 3],
    ],
];
```

The options are `name` and a job's (`schedule`, `timezone`, `grace`, `timeout`, `maxDuration`, `budget`, `expect`, `failuresBeforeAlert`, `description`, `tags`; see [PHP](/docs/php/#api)), or `true` for none.

### Commands

A listed command's run is recorded as `craft <route>` runs it, with the trigger `"command"`: ok, failed with `Exited with code N` for a non-zero exit, or failed with the exception that ended it. A listed command that another runs, and whose exception that one catches, is failed when the caller finishes. Its job is `craft:<route>` with slashes as colons (`craft:resave:entries`) unless `name` says otherwise, and its schedule is what you give, so a command the crontab stopped running is reported missed.

A command of your own can carry its options in code instead, with the `WatchCommand` behavior (`actions` limits it to some of the controller's actions):

```php
public function behaviors(): array
{
    return [...parent::behaviors(), 'cronwatch' => [
        'class' => \Cronwatch\Craft\WatchCommand::class,
        'schedule' => '0 4 * * *',
        'grace' => '15m',
    ]];
}
```

`config/cronwatch.php` wins over the behavior for a route both name. A behavior's job is declared when its command runs, so a behavior removed leaves its job's schedule behind: forget the job from the dashboard then.

A command writes to the terminal, which PHP cannot read back, so its run's output is what it logs:

```php
public function actionSend(): int
{
    $sent = Reports::sendAll();
    \Cronwatch\Cronwatch::current()?->log('Sent', $sent, 'reports');
    \Cronwatch\Cronwatch::current()?->metric('sent', $sent);
    return ExitCode::OK;
}
```

### Queue jobs

A listed class, or one marked with the attribute, is recorded wherever the queue runs it (`craft queue/run`, `queue/listen`, or the runner a Control Panel request starts), with the trigger `"queue"`:

```php
use Cronwatch\Watch;

#[Watch(grace: '30m', failuresBeforeAlert: 3)]
final class SyncInventory extends \craft\queue\BaseJob { /* ... */ }
```

Each attempt is a run of its own, so failing attempts open one alert and the attempt that succeeds closes it with a recovery, whether the queue retries the job or gives up. The job is named after its class, backslashes as dots (`modules.jobs.SyncInventory`), unless `name` says otherwise. Craft's own jobs (search indexes, resaving elements, image transforms) are not watched unless listed: they run on every save and have nothing to be missed.

A command or job taken out of `config/cronwatch.php` keeps its history and is declared again without its schedule at the next check, so it is never reported missed.

## The check

Missed and stuck runs are found by a check. Craft CMS has nothing to run it on a timer (a check queued as a job would stop with the queue it watches), so run it from the crontab every five minutes, beside the commands it watches:

```
0 3 * * *    cd /var/www/site && php craft resave/entries
*/5 * * * *  cd /var/www/site && php craft queue/run
*/5 * * * *  cd /var/www/site && php craft cronwatch/check
```

`craft cronwatch/check` declares every listed command and queue job, finds missed and stuck runs, sends their alerts, retries alerts no channel accepted and prunes old runs, and prints `cronwatch: checked 4 jobs, sent 0 alerts`; an error is one line on standard error and exit status 1. Run one checker per store.

## The store

The tables are in Craft's database, through a connection of CronWatch's own made from Craft's (its DSN, credentials, PDO attributes, and Postgres's schema), so a run recorded inside Craft's transaction stays recorded when the transaction rolls back. The plugin's install migration makes the tables and its uninstall drops them.

## Settings

Settings, Plugins, CronWatch:

- **Email alerts to** (`emailTo`): sent through Craft's mailer, with the library's subject, text and HTML.
- **Slack incoming webhook URL** (`slackWebhookUrl`), **Webhook URL** (`webhookUrl`) and **Webhook signing secret** (`webhookSecret`): the library's channels; the webhook is signed with the secret in `X-CronWatch-Signature` when there is one.
- **Grace** (`grace`, 10 minutes by default).

Each field takes an environment variable (`$SLACK_WEBHOOK_URL`), so a credential need not be in project config. Anything set in `config/cronwatch.php` wins over the form, whose fields it sets are shown disabled; Craft keeps plugin settings in project config, so a production site that disallows admin changes sets them there:

```php
return [
    'emailTo' => 'ops@example.com',
    'slackWebhookUrl' => '$SLACK_WEBHOOK_URL',
    'apiToken' => '$CRONWATCH_TOKEN',
    // 'commands' => [...], 'queueJobs' => [...],
];
```

Alerts link to the job's page in the Control Panel, at `baseCpUrl` when it is set, else at the site's `@web`. Where `@web` is not set in config, Craft takes it from each request, so an alert sent from a web request (a queue job the Control Panel ran) links to the primary site's URL instead, and a site whose URL is `@web` itself sends alerts without a link; set `baseCpUrl` or `@web` for links everywhere.

Nothing leaves the site until a channel is set; with none, alerts go to Craft's log (the `cronwatch` category), as do failures outside jobs. A listener adds channels, any of the library's ([PHP](/docs/php/#email-sms-and-error-trackers)) or a callable taking the `Cronwatch\Alert`:

```php
use Cronwatch\Craft\AlertsEvent;
use Cronwatch\Craft\Plugin;
use yii\base\Event;

Event::on(Plugin::class, Plugin::EVENT_ALERTS, function (AlertsEvent $event) {
    $event->channels[] = new \Cronwatch\Alerts\Discord(\craft\helpers\App::env('DISCORD_WEBHOOK_URL'));
});
```

## The dashboard

CronWatch in the Control Panel's navigation (`admin/cronwatch`), for users with access to the plugin: the jobs' health, the last 24 hours as a lane per job, each job's week, runs and output. These are the library's pages ([Dashboard and API](/docs/dashboard/)), shown in the Control Panel with Craft's sign-in standing for the dashboard's token. Silencing, forgetting and "Run check now" need the "Silence, forget and check jobs from the dashboard" permission as well, and carry Craft's CSRF token.

The JSON API that [`@cronwatch/mcp`](/docs/mcp/) talks to is off (404) until a token is set (`apiToken`, or the `CRONWATCH_TOKEN` environment variable); it is then at `/cronwatch/api` on the site's URL, answering requests that carry the token as a bearer:

```bash
claude mcp add cronwatch -e CRONWATCH_URL=https://example.com/cronwatch -e CRONWATCH_TOKEN=... -- npx -y @cronwatch/mcp
```

## Tests

The plugin records through Craft's database, so a test that runs a command in a process of its own (`php craft resave/entries`) records it like any other. The client the plugin uses is `Plugin::getInstance()->getRecorder()->client()`, for asserting on runs (`->runs('craft:resave:entries')`) or for declaring and running a job of your own (`->job('nightly-export', [...])->run(...)`; see [PHP](/docs/php/#declare-and-run-a-job)).
