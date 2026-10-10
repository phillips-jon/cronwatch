# CronWatch for Craft CMS

Monitoring for the work a Craft CMS site does in the background: its queue jobs and the console commands its crontab runs. Every run is recorded in the site's own database, and you are told when a run is missed, fails, gets stuck, or runs much slower than usual, and again when it recovers. No server to run, no account to make.

This is the Craft CMS plugin of [the CronWatch library](https://cronwatch.dev/) (`cronwatch/cronwatch`), which also watches jobs in TypeScript, Ruby, Python, Go, Rust, Elixir, Java, and .NET apps, plain PHP, Laravel, Symfony, WordPress, and Drupal, and keeps the same tables in every language.

## Requirements

Craft CMS 5.3 or newer, PHP 8.2 or newer, and Craft's own database (MySQL 8.0.13 or newer, MariaDB 10.6 or newer, or Postgres).

## Install

```
composer require cronwatch/craft
php craft plugin/install cronwatch
```

Or from the [Plugin Store](https://plugins.craftcms.com/cronwatch) in the Control Panel.

Installing makes three tables in Craft's database (`cronwatch_jobs`, `cronwatch_runs`, and `cronwatch_state`, after Craft's table prefix); uninstalling drops them.

## What is watched

Craft CMS has no scheduler of its own: scheduled work is console commands the server's crontab runs, and queue jobs. Both are watched when you say so, in `config/cronwatch.php`:

```php
<?php
return [
    // Console commands the crontab runs, by route, with what the crontab says.
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

- **Commands.** A listed command's run is recorded as `craft <route>` runs it: ok, failed with `Exited with code N` for a non-zero exit, or failed with the exception that ended it. Its job is `craft:<route>` (`craft:resave:entries`) unless `name` says otherwise, and its schedule is what you give, so a command the crontab stopped running is reported missed. A command of your own can instead carry its options with the `Cronwatch\Craft\WatchCommand` behavior:

  ```php
  public function behaviors(): array
  {
      return [...parent::behaviors(), 'cronwatch' => [
          'class' => \Cronwatch\Craft\WatchCommand::class,
          'schedule' => '0 4 * * *',
      ]];
  }
  ```

  The settings win over the behavior for a route both name.
- **Queue jobs.** A listed class, or one marked `#[Cronwatch\Watch]`, is recorded wherever the queue runs it (`craft queue/run`, `queue/listen`, or the runner a Control Panel request starts), each attempt a run of its own, so failing attempts open one alert and the attempt that succeeds closes it. Craft's own jobs (search indexes, resaving) are not watched unless listed: they run on every save and have nothing to be missed.

Inside a watched command or job, `Cronwatch\Cronwatch::current()?->log('...')` adds to the run's output and `->metric('name', 1.5)` records a number.

## The check

Missed and stuck runs are found by a check, `php craft cronwatch/check`, which prints `cronwatch: checked 4 jobs, sent 0 alerts`. Run it from the crontab every five minutes:

```
*/5 * * * * cd /var/www/site && php craft cronwatch/check
```

## Settings

Settings, Plugins, CronWatch: where alerts go (email through Craft's mailer, a Slack incoming webhook, a webhook, signed when given a secret, and under More channels Discord, email through Resend, Postmark, SendGrid, Mailgun, or Amazon SES, text messages through Twilio, and Sentry, Honeybadger, Datadog, Rollbar, Bugsnag, or New Relic, each once its required fields are set) and the grace a run is given (10 minutes by default). "Send a test alert" sends one to every channel the saved settings name and says what each answered. Each field takes an environment variable (`$SLACK_WEBHOOK_URL`), so a credential need not be in project config, and anything set in `config/cronwatch.php` wins over the form. Nothing leaves the site until a channel is set; with none, alerts go to Craft's log. A listener on `Cronwatch\Craft\Plugin::EVENT_ALERTS` adds channels (any of the library's, or a callable).

## The dashboard

CronWatch in the Control Panel's navigation, for users with access to the plugin: the jobs' health, the last day as a timeline, each job's runs and output. Silencing, forgetting, and "Run check now" need the "Silence, forget, and check jobs from the dashboard" permission as well, and carry Craft's CSRF token.

The JSON API that [`@cronwatch/mcp`](https://www.npmjs.com/package/@cronwatch/mcp) talks to is off until a token is set (`'apiToken' => '$CRONWATCH_TOKEN'` in `config/cronwatch.php`, or the `CRONWATCH_TOKEN` environment variable); it is then at `https://example.com/cronwatch/api`, with the token as a bearer token.

## License

MIT, as the library.
