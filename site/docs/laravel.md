---
title: Laravel
description: cronwatch/cronwatch in a Laravel app: every scheduled task watched with no code changes, per-task options, queued jobs, the check in the scheduler, the store in the app's database and the dashboard behind a gate.
order: 3.71
group: PHP
---

# Laravel

`cronwatch/cronwatch` is the PHP port of `@cronwatch/sdk`: the same conditions, the same alert text and the same stored rows. In a Laravel app it watches every task in the schedule with no code changes, records queued jobs that opt in, schedules its own check, keeps its tables in the app's database and serves the dashboard behind a gate. It needs PHP 8.2 or newer and is tested on Laravel 12 and 13.

## Install

```bash
composer require cronwatch/cronwatch
php artisan migrate
```

Package discovery registers the service provider, so there is nothing to add to `bootstrap/providers.php`. The migration it loads makes the three tables (`cronwatch_jobs`, `cronwatch_runs`, `cronwatch_state`) in the app's database, so another language can share them: on SQLite or Postgres any port, on MySQL or MariaDB the Go, Rust, Elixir, Java and .NET ports.

Then say where alerts go, in `.env`:

```
CRONWATCH_SLACK_WEBHOOK_URL=https://hooks.slack.com/services/...
CRONWATCH_MAIL_TO=ops@example.com
CRONWATCH_TOKEN=a-long-random-string
```

That is all. With no channel set, alerts are written to the app's log.

Everything else is in `config/cronwatch.php`, and every value there reads the environment, so most apps never publish it. To keep a copy:

```bash
php artisan vendor:publish --tag=cronwatch-config
php artisan vendor:publish --tag=cronwatch-migrations   # optional: the migration, into database/migrations
```

## What is watched

Every task in the app's schedule (`routes/console.php`, or `withSchedule()` in `bootstrap/app.php`) is a job, and every run `schedule:run` makes of it is recorded, through the scheduler's own events:

- A run starts when Laravel starts the task, with the trigger `"schedule"`.
- A command that exits non-zero fails with `Exited with code N`; a callback that throws fails with the exception, and one that returns `false` with `Returned false`. A callback's return value is treated as `run()`'s: a string is the output, and an HTTP response of 400 or more fails the run.
- A command's output is what it wrote: its own file (`->sendOutputTo()`, or `->appendOutputTo()` read from where the file stood when the run started), or, for a task that sends its output nowhere (Laravel's default), a temporary file of CronWatch's own for the run. At most the last 256 KB is read. A failed command's output is kept with its error.
- A task Laravel skips (a filter said no, the schedule is paused, `->withoutOverlapping()` found the last run still going) records nothing.
- A task `->onOneServer()` is recorded on the server that ran it, and a task `->runInBackground()` is finished by `schedule:finish`, which Laravel runs when the command ends, with its exit code and output. Sub-minute tasks (`->everyTenSeconds()`) record every run.

A command runs in a process of its own, so its output is how it reports. Inside a callback (`Schedule::call()`), `Cronwatch\Cronwatch::current()` is the run's context:

```php
Schedule::call(function () {
    $count = Order::prune();
    \Cronwatch\Cronwatch::current()?->log('Pruned', $count, 'orders');
    \Cronwatch\Cronwatch::current()?->metric('pruned', $count);
})->daily()->name('prune-orders');
```

### Names and schedules

A job is named after:

- a command, as written without `php` and `artisan`: `emails:send`. One with arguments has them too, with the characters a name cannot hold made `-` and a short hash added: `emails:send --force` is `emails:send-force-3ad53ba5`.
- a shell command (`Schedule::exec()`), the same way.
- a callback, after its `->name()` or `->description()`, else its class and method, else, for a closure, `closure:<file>:<line>`, which moves when the line does. Name your closures.
- a queued job (`Schedule::job()`), after its class, backslashes as dots: `App.Jobs.SendReport`.

The schedule is the task's own cron expression and timezone (`->timezone()`, else the app's). What CronWatch expects is exactly what the scheduler runs, so a task that stops running is reported missed.

A task with filters (`->when()`, `->skip()`, `->between()`, `->unlessBetween()`) does not run at every time its expression names, so its job has no schedule: its failures, slow runs and stuck runs are still watched, and it is never reported missed. A task outside the current environment (`->environments()`) is not watched. Two tasks with one name on different schedules are one job without a schedule, reported once to the log; give each its own name.

Jobs are declared as `schedule:run` starts and at every check, so a task that has never run is known. A task taken out of the schedule keeps its history and is declared again without its schedule at the next check, so it is never reported missed. Jobs are tagged `laravel-scheduler` and `laravel-scheduler:<app>`, the app's name (`CRONWATCH_APP_ID`, else `APP_NAME`). Two apps sharing one database and table prefix need different names (Laravel's default `APP_NAME` is `Laravel`), or each would take the other's tasks for its own tasks taken out.

## Options per task

`->cronwatch([...])` gives a task a job's options, and `->cronwatch(false)` leaves it out:

```php
use Illuminate\Support\Facades\Schedule;

Schedule::command('reports:build')->dailyAt('02:00')
    ->cronwatch(['name' => 'nightly-report', 'grace' => '15m', 'timeout' => '30m', 'expect' => 'Report written']);

Schedule::command('orders:sync')->everyFifteenMinutes()->when(fn () => config('shop.sync'))
    ->cronwatch(['schedule' => '*/15 * * * *']);   // a filtered task, given the schedule it keeps

Schedule::command('cache:prune-stale-tags')->hourly()->cronwatch(false);
```

It takes `name` and the options of a job declared by hand: `schedule`, `timezone`, `grace`, `timeout`, `maxDuration`, `budget`, `expect`, `failuresBeforeAlert`, `description` and `tags` (see [PHP](/docs/php/#api)). `defaults` in `config/cronwatch.php` applies `grace`, `timeout`, `timezone` and `failuresBeforeAlert` to every job that sets none, and `schedule.exclude` lists job names to leave out. `CRONWATCH_WATCH_SCHEDULE=false` stops watching the schedule altogether; the check is still scheduled unless `CRONWATCH_SCHEDULE_CHECK=false`.

## Queued jobs

A queued job is watched when it opts in, with the attribute (its options as named arguments) or the interface (`CRONWATCH_WATCH_QUEUE=false` stops watching queued jobs altogether):

```php
use Cronwatch\Watch;

#[Watch(grace: '15m', failuresBeforeAlert: 3)]
final class SendNightlyReport implements ShouldQueue
{
    use Queueable;

    public function handle(): void
    {
        $sent = Report::sendAll();
        \Cronwatch\Cronwatch::current()?->log('Sent', $sent, 'reports');
    }
}
```

`implements Cronwatch\Laravel\ShouldBeWatched` does the same, with the options from a static `cronwatch()` method returning the options array when the class has one. `#[Watch(enabled: false)]` leaves a subclass out. The job is named after its class, backslashes as dots (`App.Jobs.SendNightlyReport`), unless `name` says otherwise.

Every attempt is a run of its own, recorded in the worker that ran it with the trigger `"queue"`, so the rules of every other port's queues hold: failing attempts open one failed alert, the attempt that succeeds closes it with a recovery, and `failuresBeforeAlert` rides through retries. A job that hits its timeout is failed before the worker kills itself. A job released back onto the queue without an exception (a `RateLimited` or `WithoutOverlapping` middleware, or `$this->release()`) did not run, so its attempt is taken back: nothing is recorded or alerted, and the job's count of failures in a row is left as it was. A queued listener, mailable or notification is watched by its own class. The sync queue records the same way.

A watched class that the scheduler dispatches (`Schedule::job(new SendNightlyReport)->dailyAt('02:00')`) is one job: the scheduler declares the schedule under the queued job's name and options, and the worker records the runs, so a job that is dispatched but never handled is still reported missed.

## Jobs of your own

Anything else (a command the system crontab runs, a script, a controller) can declare and run a job through the client, which the container holds as a singleton:

```php
use Cronwatch\Cronwatch;
use Cronwatch\Job\JobContext;

app(Cronwatch::class)->job('partner-export', ['schedule' => '0 3 * * *', 'timeout' => '2h'])
    ->run(function (JobContext $job) {
        $job->log('Exported', PartnerExport::run(), 'rows');
    });
```

Declare such a job in a service provider's `boot()` as well if it must be reported missed before its first run. A platform cron that calls a URL can call a route: `handler()` checks `Authorization: Bearer <CRON_SECRET>`, runs the job and answers with how it went.

```php
// routes/api.php (routes/web.php would put Laravel's CSRF check in the way)
use Cronwatch\Cronwatch;
use Cronwatch\Job\JobContext;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Route;

Route::post('/cron/nightly', app(Cronwatch::class)
    ->job('nightly-report', ['schedule' => '0 2 * * *'])
    ->handler(fn (JobContext $job, Request $request) => Report::build())
    ->laravel());
```

`start()` and `resume()` span a run across requests or jobs; see [PHP](/docs/php/#runs-that-span-calls) and [handler](/docs/php/#jobs-a-url-starts).

## The check

A task that never ran records nothing, so something has to look. The provider schedules `cronwatch:check` every five minutes in the app's own scheduler, which is already running every minute wherever scheduled tasks work, so there is no step to add. It declares the schedule, finds missed and stuck runs, sends their alerts, retries alerts no channel accepted and prunes old runs. `CRONWATCH_CHECK_CRON` changes how often, and `CRONWATCH_SCHEDULE_CHECK=false` leaves it out, for a crontab line of your own:

```
*/5 * * * *  cd /var/www/app && php artisan cronwatch:check
```

It prints `cronwatch: checked 3 jobs, sent 1 alert` (nothing with `--quiet`); anything that goes wrong is one line on standard error and exit status 1. The check itself is never a job. Run one checker per store.

If the scheduler itself stops (its crontab line is gone, the server is down), the check stops with it, and nothing inside the app can say so. Pair it with an uptime monitor for that case (see [Limits](/docs/limits/)).

## The store

`CRONWATCH_STORE` picks it:

- `database`, the default: the app's database (MySQL 8.0.13 or newer, MariaDB 10.6 or newer, Postgres or SQLite), the default connection or `CRONWATCH_DB_CONNECTION`. CronWatch reads that connection's settings as Laravel resolved them (a `DB_URL`, the write side of a read and write split, SSL options, Postgres's `sslmode` and `search_path`) and opens a connection of its own with them, so its writes never join a transaction the app has open: a run recorded inside `DB::transaction()` stays recorded when the transaction rolls back. The tables are CronWatch's names (`CRONWATCH_TABLE_PREFIX`, default `cronwatch_`); the connection's own table prefix does not apply, so every port reads the same tables. SQL Server is not supported.
- `sqlite`: a file of its own, `storage/cronwatch/cronwatch.db` unless `CRONWATCH_SQLITE_PATH` says otherwise.
- `memory`: forgets when the process ends; for tests.

`php artisan migrate` runs the package's migration (`CRONWATCH_MIGRATIONS=false` leaves it out). Each process also runs `CREATE TABLE IF NOT EXISTS` on first use, as every store does; where the app's database user may not create tables, set `CRONWATCH_CREATE_TABLES=false` and let the migration make them.

## Alerts

| Variable | |
|---|---|
| `CRONWATCH_MAIL_TO` | one address or several, separated by commas, sent through the app's mailer with the library's subject, text and HTML |
| `CRONWATCH_MAIL_FROM`, `CRONWATCH_MAILER`, `CRONWATCH_MAIL_SUBJECT_PREFIX` | the sender (default the mailer's `mail.from`), a mailer from `config/mail.php`, and a subject prefix |
| `CRONWATCH_SLACK_WEBHOOK_URL` | a Slack incoming webhook |
| `CRONWATCH_DISCORD_WEBHOOK_URL` | a Discord webhook |
| `CRONWATCH_WEBHOOK_URL`, `CRONWATCH_WEBHOOK_SECRET` | a signed JSON webhook |
| `CRONWATCH_LOG_CHANNEL` | a channel from `config/logging.php`, written to as well |
| `CRONWATCH_TRIAGE=true` | Claude triage, reading `ANTHROPIC_API_KEY`; `CRONWATCH_TRIAGE_MODEL` and `CRONWATCH_TRIAGE_CONTEXT` |

Email, Slack and Discord alerts link to the job's page on the dashboard. `alerts.channels` in `config/cronwatch.php` takes more: any of the library's channels (Resend, Postmark, SES, Twilio, Sentry and the rest; see [PHP](/docs/php/#email-sms-and-error-trackers)), or class names the container makes. `CRON_SECRET`, `CRONWATCH_RETENTION` (default `30d`) and `CRONWATCH_DELIVER` (`check` for a process that cannot reach the network) are read too. Failures outside jobs (the store, a channel) go to the app's log.

To build the client yourself, bind `Cronwatch\Cronwatch` again in one of your own providers' `register()`, which runs after the package's.

## The dashboard

The dashboard and JSON API are at `/cronwatch` (`CRONWATCH_PATH`, or `CRONWATCH_DOMAIN` for a domain of its own): the jobs' health, the last 24 hours as a lane per job, each job's week, runs and output, and the endpoints the [MCP server](/docs/mcp/) uses. They are the SDK's pages and API; see [Dashboard and API](/docs/dashboard/).

Who may open it is the `viewCronwatch` gate, asked with the signed-in user. Until you define it, it lets anyone in the `local` environment in, and no one elsewhere, as Horizon's and Telescope's gates do. Define it in a service provider's `boot()`:

```php
use Illuminate\Support\Facades\Gate;

Gate::define('viewCronwatch', fn (User $user) => $user->is_admin);
```

A request the gate lets in is served with the app's sign-in standing for the dashboard's token. A request carrying a bearer token skips the gate and must carry `CRONWATCH_TOKEN` instead (or, for `/cronwatch/api/check`, `CRON_SECRET`), which is how the MCP server and a platform cron reach it:

```bash
claude mcp add cronwatch -e CRONWATCH_URL=https://app.example.com/cronwatch -e CRONWATCH_TOKEN=... -- npx -y @cronwatch/mcp
```

Laravel's CSRF middleware is taken off the dashboard's routes, since its forms carry no Laravel token and the routes refuse a cross-site write themselves; the origin they compare with is the request's as Laravel sees it, so the app's trusted proxies apply. `CRONWATCH_DASHBOARD=false` leaves the routes out.

## Tests

In tests, keep runs in memory, or turn CronWatch off:

```xml
<!-- phpunit.xml -->
<env name="CRONWATCH_STORE" value="memory"/>
<env name="CRONWATCH_ENABLED" value="false"/>
```

`CRONWATCH_ENABLED=false` watches nothing, schedules no check and mounts no dashboard; `app(Cronwatch::class)` still works, so code that runs jobs by hand runs the same. The `testing` environment counts as development, so the in-memory store does not warn. With the memory store, a test can run the schedule with `$this->artisan('schedule:run')` and assert on `app(Cronwatch::class)->runs('prune-orders')`.
