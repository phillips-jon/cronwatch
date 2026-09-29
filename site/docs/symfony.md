---
title: Symfony
description: cronwatch/cronwatch in a Symfony app: a bundle that watches every Scheduler message with no code changes, Messenger messages that opt in, the check in your default schedule, and the dashboard behind your security.
order: 3.72
group: PHP
---

# Symfony

`cronwatch/cronwatch` includes a Symfony bundle. It watches every recurring message of every schedule through the Scheduler's own events, records Messenger messages that opt in, adds its check to the schedule your worker already consumes, keeps its tables in the app's database and serves the dashboard behind your security. It needs PHP 8.2 or newer and is tested on Symfony 6.4, 7.4 and 8.1 (8.x needs PHP 8.4).

## Install

```bash
composer require cronwatch/cronwatch
```

Register the bundle and configure it:

```php
// config/bundles.php
return [
    // ...
    Cronwatch\Symfony\CronwatchBundle::class => ['all' => true],
];
```

```yaml
# config/packages/cronwatch.yaml
cronwatch:
    # store: '%env(DATABASE_URL)%'    # the default; or sqlite:///%kernel.project_dir%/var/cronwatch.db
    alerts:
        slack: '%env(CRONWATCH_SLACK_WEBHOOK_URL)%'
        mailer: { to: ops@example.com, from: cronwatch@example.com }
```

The Scheduler watching needs `symfony/scheduler` and `symfony/messenger`, which an app that schedules anything already has. The three tables (`cronwatch_jobs`, `cronwatch_runs`, `cronwatch_state`) are made on first use, in the app's database, so another language can share them: on SQLite or Postgres any port, on MySQL or MariaDB the Go and Rust ports.

## What is watched

Every recurring message of every schedule (`#[AsSchedule]` providers, `#[AsCronTask]` and `#[AsPeriodicTask]`) is a job, and every time the worker consuming that schedule handles it is a run, recorded through the Scheduler's `PreRunEvent`, `PostRunEvent` and `FailureEvent`, with the trigger `"scheduler"`:

- The run ends ok with the handler's result: a string is the output, and an HTTP response of 400 or more fails the run.
- A handler that throws fails the run with the exception (taken out of Messenger's `HandlerFailedException`), and the exception goes on as before.
- Inside the handler, `Cronwatch\Cronwatch::current()` is the run's context:

```php
#[AsMessageHandler]
final class BuildReportHandler
{
    public function __invoke(BuildReport $message): string
    {
        $path = $this->reports->build();
        \Cronwatch\Cronwatch::current()?->metric('pages', $this->reports->pages());
        return "Report written: {$path}";
    }
}
```

### Names and schedules

A job is named after:

- a message object, its class with backslashes as dots: `App.Message.BuildReport`.
- a command (`#[AsCronTask]` on a command, `RunCommandMessage`), the command as written, with the characters a name cannot hold made `-` and a short hash added: `app:prune --days=30` is `app:prune-days-30-22ea7e48`.
- a service method (`#[AsCronTask]` on a service, `ServiceCallMessage`), the service's id and the method unless it is `__invoke`: `App.Scheduler.Cleanup.purge`.
- a message a schedule sends on to a transport (`RedispatchMessage`), the message it carries.

A schedule other than `default` puts its name in front: `reports:App.Message.BuildReport`.

The schedule is the trigger's: a `CronExpressionTrigger`'s expression and zone (a hashed `#` expression as Symfony resolved it), a `PeriodicalTrigger`'s interval as `every` and the interval in the largest units that fit (3600 seconds is `every 1h`, 5400 `every 1h30m`, 90 `every 1m30s`), a `JitterTrigger`'s inner trigger. A trigger that does not fire at fixed times (`ExcludeTimeTrigger`, `CallbackTrigger`, a calendar interval such as `1 month`) leaves the job without a schedule, reported once: its failures, slow runs and stuck runs are still watched, but it is never reported missed. Two messages with one name on different schedules are one job without a schedule.

Jobs are declared by every check, so a message that has never run is known. A message taken out of a schedule keeps its history and is declared again without its schedule, so it is never reported missed. Jobs are tagged `symfony-scheduler` and `symfony-scheduler:<app>`, where the app is `app_id`, else `app-` and a hash of the kernel's secret (`APP_SECRET`), else of the project directory when there is no secret; two apps sharing one database and table prefix need different ones.

## Options per message

On the message's class:

```php
use Cronwatch\Watch;

#[Watch(name: 'nightly-report', grace: '15m', timeout: '30m', expect: 'Report written')]
final class BuildReport
{
}
```

Or by job name in the configuration, for messages you did not write:

```yaml
cronwatch:
    defaults: { grace: 10m }
    scheduler:
        jobs:
            'App.Message.BuildReport': { name: nightly-report, grace: 15m }
            'app:cache-warm': false        # left out
        exclude: ['app:heartbeat']
```

The options are `name` and a job's (`schedule`, `timezone`, `grace`, `timeout`, `maxDuration`, `budget`, `expect`, `failuresBeforeAlert`, `description`, `tags`; see [PHP](/docs/php/#api)); `#[Watch(enabled: false)]` and `false` leave a message out. `defaults` applies `grace`, `timeout`, `timezone` and `failuresBeforeAlert` to every job that sets none. `scheduler: { watch: false }` turns the Scheduler watching off.

## Messenger messages

A message class marked `#[Cronwatch\Watch]` is recorded where a worker handles it, whatever sent it, with the trigger `"messenger"`. Every attempt is a run of its own, so a retried message's failing attempts open one failed alert and the attempt that succeeds closes it with a recovery; `failuresBeforeAlert` rides through retries. A message handled synchronously never reaches a worker and is not recorded.

A watched message that a schedule sends on to a transport (`RecurringMessage` with a `RedispatchMessage`) is one job: the schedule declares the schedule under the message's name, and the worker that handles it records the runs, so a message that is sent but never handled is still reported missed. `messenger: { watch: false }` turns this off.

## The check

A message that never ran records nothing, so something has to look. The bundle adds its check to your `default` schedule, every five minutes, so the worker that already runs your scheduled messages runs it too:

```bash
bin/console messenger:consume scheduler_default
```

Nothing more is needed while that worker runs. A check in a schedule nobody consumes does nothing, so the command says where it is:

```bash
bin/console cronwatch:check --status
# cronwatch: the check runs every 5 minutes in the "default" schedule, only while a worker consumes it: bin/console messenger:consume scheduler_default
```

`debug:scheduler` lists it too. To move it:

```yaml
cronwatch:
    check:
        schedule: cronwatch      # a schedule of its own: consume scheduler_cronwatch as well
        frequency: 5 minutes     # a period, or a cron expression
```

`check: { schedule: false }` leaves it out of every schedule, for a crontab line instead:

```
*/5 * * * *  cd /var/www/app && bin/console cronwatch:check
```

`bin/console cronwatch:check` declares every schedule's jobs, finds missed and stuck runs, sends their alerts, retries alerts no channel accepted and prunes old runs, and prints `cronwatch: checked 3 jobs, sent 1 alert`; anything that goes wrong is one line on standard error and exit status 1. The check is never a job. Run one checker per store.

If the worker stops, the check stops with it, and nothing inside the app can say so. Pair it with an uptime monitor for that case (see [Limits](/docs/limits/)).

## The store

`store` is a URL written as Doctrine writes one: `mysql://`, `postgresql://`, `sqlite:///<path>` or `memory`. The default is the app's `DATABASE_URL`, else `var/cronwatch.db`. MySQL 8.0.13 or newer, MariaDB 10.6 or newer, Postgres and SQLite are supported; Doctrine's `serverVersion` and a Postgres `charset` are left out. The store always opens a connection of its own, in autocommit mode, so a run recorded inside a Doctrine transaction stays recorded when the transaction rolls back.

`table_prefix` names the tables (default `cronwatch_`). Each process runs `CREATE TABLE IF NOT EXISTS` on first use; where the app's database user may not create tables, make them once from a user who may and set `create_tables: false`. `store_service` names a `Cronwatch\Store\Store` service of your own instead.

## Alerts

```yaml
cronwatch:
    alerts:
        mailer: { to: [ops@example.com], from: cronwatch@example.com, subject_prefix: '[prod]' }
        slack: '%env(CRONWATCH_SLACK_WEBHOOK_URL)%'
        discord: '%env(CRONWATCH_DISCORD_WEBHOOK_URL)%'
        webhook: { url: '%env(CRONWATCH_WEBHOOK_URL)%', secret: '%env(CRONWATCH_WEBHOOK_SECRET)%' }
        log: true                       # the logger as well
        services: [app.pagerduty_channel]
    triage: { enabled: true, context: 'A Symfony 7 app on Postgres.' }   # reads ANTHROPIC_API_KEY
    retention: 30d
    deliver: now                        # check: queue alerts for another process's check to send
```

Email goes through `symfony/mailer` with the library's subject, text and HTML. `services` takes the ids of `Cronwatch\Alerts\AlertChannel` services, so any of the library's channels (Resend, Postmark, SES, Twilio, Sentry and the rest; see [PHP](/docs/php/#email-sms-and-error-trackers)) can be defined as a service and listed. With no channel, alerts go to the logger, Monolog's `cronwatch` channel when the app has Monolog, as do failures outside jobs. `cron_secret` is the secret `handler()` and `/api/check` take (default `CRON_SECRET`).

The client is the `Cronwatch\Cronwatch` service (alias `cronwatch`), autowired anywhere, so a job of your own is `$cw->job('partner-export', [...])->run(fn ($job) => ...)`. A platform cron that calls a URL can call a controller:

```php
use Cronwatch\Cronwatch;
use Cronwatch\Job\JobContext;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\Routing\Attribute\Route;

#[Route('/cron/nightly', methods: ['POST'])]
public function nightly(Request $request, Cronwatch $cw): Response
{
    return $cw->job('nightly-report', ['schedule' => '0 2 * * *'])
        ->handler(fn (JobContext $job, Request $request) => $this->reports->build())($request);
}
```

It checks `Authorization: Bearer <CRON_SECRET>`, runs the job and answers with how it went; see [handler](/docs/php/#jobs-a-url-starts).

## The dashboard

Import the routes under a prefix, and put the prefix behind your security:

```yaml
# config/routes/cronwatch.yaml
cronwatch:
    resource: '@CronwatchBundle/config/routes.php'
    prefix: /cronwatch

# config/packages/security.yaml
security:
    access_control:
        - { path: ^/cronwatch/api, roles: PUBLIC_ACCESS }   # the MCP server brings CRONWATCH_TOKEN instead
        - { path: ^/cronwatch, roles: ROLE_ADMIN }
```

A signed-in user granted `dashboard.role` (`ROLE_ADMIN` by default) is served with the app's sign-in standing for the dashboard's token. Anyone else, and every request carrying a bearer token, must present the dashboard's token (`dashboard.token`, else `CRONWATCH_TOKEN`), or `CRON_SECRET` for `/cronwatch/api/check`, so a prefix left outside the firewall is still closed. That is how the [MCP server](/docs/mcp/) reaches the API:

```bash
claude mcp add cronwatch -e CRONWATCH_URL=https://app.example.com/cronwatch -e CRONWATCH_TOKEN=... -- npx -y @cronwatch/mcp
```

The pages and API are the SDK's; see [Dashboard and API](/docs/dashboard/). Writes from another site are refused, and the origin compared is the one Symfony sees, so its trusted proxies apply.

## Tests

In the test environment, keep runs in memory:

```yaml
# config/packages/cronwatch.yaml
when@test:
    cronwatch:
        store: memory
```

The kernel's environment stands in for `APP_ENV`, so `test` and `dev` count as development: the in-memory store does not warn, and the dashboard with no token makes one of its own and writes its sign-in link to PHP's error log (the terminal running `symfony serve`), for a visitor the role does not let in.
