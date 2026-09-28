# cronwatch/cronwatch

Cron and scheduled-job monitoring that lives inside your PHP app. Wrap a job once; every run is recorded in a database you already have, and you are told when a run is missed, fails, gets stuck, runs slow or goes over budget. No server to run, no account to make.

This is the PHP port of [`@cronwatch/sdk`](https://www.npmjs.com/package/@cronwatch/sdk), under way: the same rules, the same alert text, the same requests to every alert channel and the same stored rows, so a PHP process and a Node process can share one SQLite file, and every port reads the tables the others write. It has the core, the stores (memory, SQLite, MySQL, MariaDB and Postgres), every alert channel, Claude triage, the pg_cron source, a `vendor/bin/cronwatch check` command, the dashboard and JSON API, a job handler for crons that call a URL, the Laravel and Symfony integrations, and a WordPress plugin; the Drupal and Craft integrations follow ([DESIGN.md](DESIGN.md) has the plan). It is not on Packagist yet.

Docs: [cronwatch.dev](https://cronwatch.dev/docs/)

## Install

PHP 8.2 or newer, and no dependencies beyond `ext-json` and `ext-pcre`: cron expressions are read by a port of [croner](https://github.com/hexagon/croner) (the parser the SDK uses) and zones come from PHP's own database. The SQLite store needs `pdo_sqlite`, the MySQL store `pdo_mysql`, and the Postgres store and the pg_cron source `pdo_pgsql`. The alert channels and triage use `ext-curl` when it is loaded and PHP's own streams otherwise.

## Use

```php
use Cronwatch\Alert;
use Cronwatch\Cronwatch;
use Cronwatch\Job\JobContext;
use Cronwatch\Store\SqliteStore;

$cw = new Cronwatch(
    store: new SqliteStore('/var/lib/app/cronwatch.db'),
    alerts: [fn (Alert $alert) => page($alert->title, $alert->message)],
);

$nightly = $cw->job('nightly-report', [
    'schedule' => '0 2 * * *', 'timezone' => 'UTC', 'grace' => '15m', 'timeout' => '30m',
    'expect' => 'Report written', 'budget' => ['cost' => 2],
]);

$nightly->run(function (JobContext $job) {
    $path = build_report();
    $job->log('Report written:', $path);   // kept with the run, shown in alerts
    $job->metric('cost', 1.2);             // watched against budgets and baselines
});
```

A run is recorded when the function returns; what it throws is recorded as the failure and thrown again, and a run cut short by `exit()` or a fatal error is recorded as failed when the process ends. `run()` returns what the function returns. `$nightly->wrap($callable)` gives a callable whose every call is a run, with `Cronwatch::current()` its context.

A PHP process does not stay up between runs, so missed and stuck runs are found by a check, every five minutes, from a second crontab line or the framework's scheduler. Put the client in a file that returns it, `cronwatch.php`:

```php
<?php
require __DIR__ . '/vendor/autoload.php';

$cw = new Cronwatch\Cronwatch(store: new Cronwatch\Store\SqliteStore('/var/lib/app/cronwatch.db'), alerts: [/* ... */]);
$cw->job('nightly-report', ['schedule' => '0 2 * * *', 'timezone' => 'UTC']);
return $cw;
```

and the crontab line is `vendor/bin/cronwatch check`, which prints `cronwatch: checked 1 job, sent 0 alerts` (and exits 1 with the reason on standard error when something is wrong):

```
*/5 * * * * cd /var/www/app && vendor/bin/cronwatch check
```

It looks for `cronwatch.php`, then `config/cronwatch.php`, in the working directory; `--bootstrap <file>` or `CRONWATCH_BOOTSTRAP` names another. The app's own scripts can `require` the same file.

A run that starts in one call and ends in another (a job that hands work to a queue, a webhook that reports back later) is one run too:

```php
$run = $nightly->start(id: $batchId);   // records a running run; a second start with this id finds it
// later, perhaps in another process
$run = $nightly->resume($batchId);
$run->log('sent 40 emails');
$run->finish();                         // or $run->fail($error), or $run->finish('text')
```

A run that is never finished is marked stuck by the first check after the job's timeout.

### Options

`job($name, [...])`: `schedule` (five or six field cron, a nickname such as `@hourly`, or `every 5m`), `timezone` (IANA; default PHP's), `grace` (default `10m`), `timeout` (default `1h`), `maxDuration`, `budget` (`['metric' => ceiling]`), `expect` (a string the output must contain, a `Cronwatch\Pattern` it must match, or a callable), `failuresBeforeAlert` (default 1), `description`, `tags`. Durations are strings like `1h30m`, milliseconds, or a `DateInterval`.

`new Cronwatch(...)`: `store`, `alerts` (channels or callables; default the console), `triage` (a callable returning a short diagnosis added to each alert), `sources`, `retention` (default `30d`), `defaults`, `redact` (secrets are blanked from output and errors by default; pass your own callable, or `false`), `deliver` (`check` queues alerts for another process's check to send), `onError` (store and channel failures; default PHP's error log), `now`.

`check()`, `jobs()`, `jobsWithRuns()`, `jobSummary($name)`, `runs($name)`, `getRun($id)`, `silence($name, '2h')`, `unsilence($name)`, `forget($name)`, `recordRun($run)`, `resumeRun($name, $id)`, `close()`.

### Stores

- `Cronwatch\Store\MemoryStore`, the default: forgets when the process ends.
- `Cronwatch\Store\SqliteStore($path, prefix: 'cronwatch_')`: one file, WAL mode. The tables, statements and JSON are the SDK's SQLite store's, byte for byte, so a Node process using `@cronwatch/sdk/sqlite` on the same file sees the same jobs, runs and state.
- `Cronwatch\Store\MysqlStore($url, prefix: 'cronwatch_')`: MySQL 8.0.13 or newer, or MariaDB 10.6 or newer, from a `mysql://` URL, a PDO DSN, the app's `PDO`, or `DATABASE_URL`. The same tables in MySQL's dialect (see DESIGN.md), with the SDK's JSON kept byte for byte. It writes through a connection of its own, so a run recorded inside the app's transaction survives a rollback.
- `Cronwatch\Store\PostgresStore($url, prefix: 'cronwatch_')`: Postgres from a `postgres://` URL, a PDO DSN, the app's `PDO`, or `DATABASE_URL`. The SDK's tables and statements, so a Node, Ruby or Python process can share the database. It writes through a connection of its own, so a run recorded inside the app's transaction survives a rollback.

### Alert channels

```php
use Cronwatch\Alerts;

$link = fn (Cronwatch\Alert $a) => "https://app.example.com/cronwatch/jobs/{$a->job}";
$cw = new Cronwatch(store: $store, alerts: [
    new Alerts\Slack(webhookUrl: getenv('SLACK_WEBHOOK_URL'), link: $link),
    new Alerts\Resend(apiKey: getenv('RESEND_API_KEY'), from: 'CronWatch <alerts@example.com>', to: ['ops@example.com']),
    new Alerts\Twilio(accountSid: getenv('TWILIO_ACCOUNT_SID'), authToken: getenv('TWILIO_AUTH_TOKEN'), from: '+15005550006', to: '+15551110000'),
]);
```

`Slack`, `Discord`, `Webhook` (signed with HMAC-SHA256 when given a `secret`), email through `Resend`, `Postmark`, `Sendgrid`, `Mailgun` or `Ses` (Amazon SES, signed with SigV4, no AWS SDK needed), SMS through `Twilio`, and the trackers `Sentry`, `Honeybadger`, `Datadog`, `Rollbar`, `Bugsnag` and `NewRelic`. Their options are the SDK's, as named arguments. Each request has a ten second deadline, follows no redirect, and never puts a credential in an error message. A channel is also any callable taking the `Alert`.

### Claude triage

```php
$cw = new Cronwatch(store: $store, alerts: $channels, triage: new Cronwatch\Triage\Anthropic(context: 'A Laravel app on Forge.'));
```

Each alert but a recovery gets a short diagnosis from Claude: the likely cause and the first thing to check. It reads `ANTHROPIC_API_KEY`, needs no Anthropic package (it sends the Messages API request itself), and never holds an alert for long: when the answer is late or the request fails, the alert goes out without one.

### pg_cron

```php
$cw = new Cronwatch(store: new PostgresStore($url), sources: [new Cronwatch\Sources\PgCron($url, prefix: 'db:')]);
```

Jobs pg_cron runs inside Postgres, where nothing can wrap them, are watched too: each check declares them from `cron.job` and copies their runs from `cron.job_run_details`.

### Dashboard and JSON API

The SDK's dashboard, page for page and byte for byte: the jobs' health, the last day as a timeline, each job's week, runs and output, silence, forget and "Run check now", and the small JSON API that [`@cronwatch/mcp`](https://www.npmjs.com/package/@cronwatch/mcp) talks to. It needs no framework. In a bare script:

```php
<?php
// public/cronwatch.php: open /cronwatch.php/ (or rewrite /cronwatch/ to this file)
$cw = require __DIR__ . '/../cronwatch.php';
$cw->routes()->serve();
```

`serve()` reads the request from PHP's superglobals and writes the answer with `header()` and `echo`. `handle(Cronwatch\Web\Request): Cronwatch\Web\Response` is the same routes for anything else, and with `psr/http-message` installed, `Cronwatch\Web\PsrHandler` (a PSR-15 request handler) and `Cronwatch\Web\PsrMiddleware` (answers under its base path, passes the rest on) take a PSR-17 factory:

```php
$factory = new Nyholm\Psr7\Factory\Psr17Factory();
$app->add(new Cronwatch\Web\PsrMiddleware($cw->routes(), $factory, $factory));   // Slim, Mezzio, any PSR-15 stack
```

`routes(token:, basePath:, origin:, trustProxy:)`:

- `token`: everything needs it, as `Authorization: Bearer <token>`, or open the dashboard once with `?token=<token>` and a cookie keeps the browser signed in. Defaults to `CRONWATCH_TOKEN`. With none, the dashboard answers 503, except in development (`CRONWATCH_ENV`, `APP_ENV` or `WP_ENVIRONMENT_TYPE` set to `development`, `dev`, `local`, `test` or `testing`), where it makes one, keeps it in a file in the system's temporary directory so every request asks for the same one, and writes a sign-in link to the server log. `false` serves it open, for behind your own auth. `/api/check` also takes the client's `cronSecret`, for a platform cron.
- `basePath`: where it is mounted. Default: the script, for a path-info URL like `/cronwatch.php/`, else `/cronwatch`.
- `origin` (`https://app.example.com`) or `trustProxy: true`: the public origin, for an app behind a proxy, used for the same-origin check on changes, the cookie's `Secure` flag and the redirects.

Changes (silence, forget, the check) are refused from another site, the pages carry a strict CSP and load nothing but their own app shell, and the dashboard installs as an app (a manifest, icons and a service worker that caches only the shell).

### A job behind a URL

For a cron that calls a URL (a platform's cron, Cloud Scheduler, a crontab line running curl), `handler()` makes a request handler that runs the job, the SDK's `handler()`:

```php
$cron = $cw->job('nightly-report', ['schedule' => '0 2 * * *'])
    ->handler(fn (JobContext $job, $request) => build_report($job));

$cron->serve();                                              // public/cron/nightly.php, from the superglobals
Route::post('/cron/nightly', $cron->laravel());              // Laravel (routes/api.php, which has no CSRF check)
return $cron($request);                                      // a Symfony (or Laravel) controller
$psr = new Cronwatch\Web\PsrJobHandler($cron, $f, $f);       // PSR-15, with a PSR-17 factory
```

The caller must send `Authorization: Bearer <secret>`: the handler's `secret:`, else the client's `cronSecret` (`CRON_SECRET` by default). With no secret at all it answers 503 outside development; `secret: false` lets anyone run the job. Each request is a recorded run, answered with `{"ok","job","run","status","durationMs"}` and 200 or 500. A function that returns a response is answered with it, and a status of 400 or more fails the run, from any job: a PSR-7 response, Symfony's or Laravel's, Laravel's HTTP client response, a `Cronwatch\Web\Response`, or an array such as `['status' => 503, 'body' => 'down']`.

### Laravel

`composer require cronwatch/cronwatch`, and package discovery does the rest (Laravel 12 and 13). Every task in the app's schedule is watched with no code changes: its runs are recorded as `schedule:run` runs it, its cron expression and timezone are its job's schedule, and `cronwatch:check` is scheduled every five minutes in the same scheduler, so a task that never ran is reported missed. Runs are kept in the app's database through a connection of CronWatch's own, so a run recorded inside a transaction survives its rollback; `php artisan migrate` makes the tables.

```
CRONWATCH_SLACK_WEBHOOK_URL=https://hooks.slack.com/services/...
CRONWATCH_MAIL_TO=ops@example.com
```

A job is named after its command (`emails:send`; one with arguments gets a short hash, `emails:send-force-1a2b3c4d`), its `->name()` or description, its queued job's class (`App.Jobs.SendReport`), or, for an unnamed closure, `closure:<file>:<line>`, which moves when the line does, so name those. Options per task, or leave one out:

```php
Schedule::command('reports:build')->dailyAt('02:00')->cronwatch(['name' => 'nightly-report', 'grace' => '15m', 'expect' => 'Report written']);
Schedule::command('cache:prune-stale-tags')->hourly()->cronwatch(false);
```

A task with `->when()`, `->skip()` or `->between()` has no schedule to miss, so its job has none unless given one. Queued jobs opt in, and then every attempt is a run (failing retries open one alert, the attempt that works closes it; an attempt released back onto the queue without an exception, by a rate limit, `WithoutOverlapping` or `$this->release()`, is not a run, neither a failure nor a success):

```php
#[Cronwatch\Watch(grace: '15m', failuresBeforeAlert: 3)]
final class SendNightlyReport implements ShouldQueue { /* Cronwatch::current()?->log(...) inside handle() */ }
```

The dashboard is at `/cronwatch`, for whoever the `viewCronwatch` gate lets in (anyone in the `local` environment, until you define it: `Gate::define('viewCronwatch', fn (User $user) => $user->is_admin)`); `@cronwatch/mcp` reaches its API with `CRONWATCH_TOKEN` as a bearer token. `php artisan vendor:publish --tag=cronwatch-config` gives `config/cronwatch.php`, where everything else is.

### Symfony

Register the bundle (`Cronwatch\Symfony\CronwatchBundle::class => ['all' => true]` in `config/bundles.php`; Symfony 6.4, 7.4 and 8.1) and configure it:

```yaml
# config/packages/cronwatch.yaml
cronwatch:
    # store: '%env(DATABASE_URL)%'    # the default; or sqlite:///%kernel.project_dir%/var/cronwatch.db
    alerts:
        slack: '%env(CRONWATCH_SLACK_WEBHOOK_URL)%'
        mailer: { to: ops@example.com, from: cronwatch@example.com }
```

Every message of every schedule (`#[AsSchedule]` providers, `#[AsCronTask]`, `#[AsPeriodicTask]`) is watched through the Scheduler's events as the worker runs it, its trigger as its job's schedule. Messenger messages marked `#[Cronwatch\Watch]` are recorded where a worker handles them, each attempt a run.

The check (which finds missed and stuck runs) is added to your `default` schedule, every five minutes, so it runs only while a worker consumes that schedule, the same worker your scheduled messages need:

```
bin/console messenger:consume scheduler_default
```

`bin/console cronwatch:check --status` says where the check is and which transport must be consumed; `debug:scheduler` lists it too. `check.schedule` puts it in another schedule (`check: { schedule: cronwatch }`, then consume `scheduler_cronwatch` as well), and `check.schedule: false` leaves it out, for a crontab line running `bin/console cronwatch:check` every five minutes. If nothing runs the check, a job that never runs is never reported. Two apps sharing one store and table prefix need different `app_id`s (see DESIGN.md). The dashboard is a route import behind your security:

```yaml
# config/routes/cronwatch.yaml
cronwatch:
    resource: '@CronwatchBundle/config/routes.php'
    prefix: /cronwatch

# config/packages/security.yaml
security:
    access_control:
        - { path: ^/cronwatch/api, roles: PUBLIC_ACCESS }   # @cronwatch/mcp brings CRONWATCH_TOKEN instead
        - { path: ^/cronwatch, roles: ROLE_ADMIN }
```

A signed-in user with `ROLE_ADMIN` (`dashboard.role`) is let in; anyone else needs the dashboard's token.

### WordPress

The CronWatch plugin (`wordpress/`, built into the plugin directory's zip with `php wordpress/build.php`) watches every WP-Cron event with no code changes: each event's runs are recorded in the site's own database, and missed, failed, stuck and slow runs are alerted by email, Slack or webhook. It adds a CronWatch menu to wp-admin, for administrators: the dashboard above, and its settings. The JSON API, for `@cronwatch/mcp`, is off until turned on there with a token. It works network wide on a multisite. WP-Cron only fires when someone visits the site, so a quiet site's events run late or not at all; the plugin's readme recommends `DISABLE_WP_CRON` and a real crontab, with `wp cronwatch check` running the check from it. See DESIGN.md for how events become jobs.

## Testing

From this directory:

```bash
composer install
vendor/bin/phpunit
```

`tests/ConformanceTest.php` replays the cases in the repository's `conformance/` directory, generated from the TypeScript SDK, and `tests/ChannelConformanceTest.php`, `tests/TriageTest.php` and `tests/PgCronTest.php` replay the channel, triage and pg_cron fixtures. The MySQL and MariaDB tests run when `CRONWATCH_TEST_MYSQL` and `CRONWATCH_TEST_MARIADB` are `mysql://` URLs, the Postgres tests when `CRONWATCH_TEST_PG` is a `postgres://` URL, and the pg_cron tests when `CRONWATCH_TEST_PGCRON` names a Postgres with pg_cron preloaded (`shared_preload_libraries=pg_cron`, and `cron.database_name` set to the URL's database). CI starts them all; locally, for example against throwaway servers:

```bash
docker run -d --rm --name cw-mysql -e MYSQL_ROOT_PASSWORD=pw -e MYSQL_DATABASE=cw -p 33061:3306 mysql:8
docker run -d --rm --name cw-mariadb -e MARIADB_ROOT_PASSWORD=pw -e MARIADB_DATABASE=cw -p 33062:3306 mariadb:10.11
docker run -d --rm --name cw-pg -e POSTGRES_PASSWORD=pw -e POSTGRES_DB=cw -p 55432:5432 postgres:16-alpine
CRONWATCH_TEST_MYSQL=mysql://root:pw@127.0.0.1:33061/cw CRONWATCH_TEST_MARIADB=mysql://root:pw@127.0.0.1:33062/cw \
  CRONWATCH_TEST_PG=postgres://postgres:pw@127.0.0.1:55432/cw vendor/bin/phpunit
```

`tests/WebGoldenTest.php` replays `packages/ruby/test/web/golden.json`, the SDK routes' answers to a fixed seed, through `handle()`, the superglobals and PSR-7, and every status, header and body must match; `tests/WebServeTest.php` runs `serve()` under `php -S`. The MCP server's end to end test drives the dashboard too: `CRONWATCH_TEST_PHP=1 npm test --workspace packages/mcp` at the root (after `composer install` here).

`tests/ChannelsTest.php` runs the default HTTP client (curl, and PHP's streams) against a local `php -S` server. The WordPress plugin's tests install WordPress with WP-CLI and run the built plugin in it, when `CRONWATCH_TEST_WORDPRESS` is a `mysql://` URL and `CRONWATCH_TEST_WPCLI` the path to `wp-cli.phar` (`CRONWATCH_TEST_WP_VERSION` picks the WordPress version).

`tests/FinishOnceTest.php` starts PHP worker processes that finish the same runs at the same moment, on SQLite and on each server. `tests/NodeCompatTest.php` shares a SQLite file with the built SDK, and `tests/ScheduleFuzzTest.php` checks thousands of generated cron expressions against croner itself; both need Node and the SDK built first (`npm ci && npm run build` at the repository root), and skip with the reason otherwise. `npm run check:php` at the root runs the suite.

`tests/Laravel/` runs the Laravel integration on Orchestra Testbench and `tests/Symfony/` the bundle on FrameworkBundle's test kernel; the dev dependencies bring the newest of each that the PHP allows (Laravel 12 and Symfony 7.4 on PHP 8.2, Laravel 13 and Symfony 8.1 on 8.4 and newer), and without them those tests are skipped. To test another series, pin it and take the other framework out, as CI's php-frameworks job does:

```bash
composer remove --dev --no-update orchestra/testbench
composer require --dev --no-update "symfony/framework-bundle:6.4.*" "symfony/scheduler:6.4.*" "symfony/messenger:6.4.*" \
  "symfony/security-bundle:6.4.*" "symfony/browser-kit:6.4.*" "symfony/console:6.4.*"
composer update && vendor/bin/phpunit tests/Symfony
```

The Laravel store tests use `CRONWATCH_TEST_MYSQL`, `CRONWATCH_TEST_MARIADB` and `CRONWATCH_TEST_PG` too.

## License

MIT
