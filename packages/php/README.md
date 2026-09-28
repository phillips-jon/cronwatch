# cronwatch/cronwatch

Cron and scheduled-job monitoring that lives inside your PHP app. Wrap a job once; every run is recorded in a database you already have, and you are told when a run is missed, fails, gets stuck, runs slow or goes over budget. No server to run, no account to make.

This is the PHP port of [`@cronwatch/sdk`](https://www.npmjs.com/package/@cronwatch/sdk), under way: the same rules, the same alert text and the same stored rows, so a PHP process and a Node process can share one SQLite file, and every port reads the tables the others write. This first phase is the core and its stores (memory, SQLite, MySQL and MariaDB); the alert channels, Postgres, the dashboard and the Laravel, Symfony, WordPress, Drupal and Craft integrations follow ([DESIGN.md](DESIGN.md) has the plan). It is not on Packagist yet.

Docs: [cronwatch.dev](https://cronwatch.dev/docs/)

## Install

PHP 8.2 or newer, and no dependencies beyond `ext-json` and `ext-pcre`: cron expressions are read by a port of [croner](https://github.com/hexagon/croner) (the parser the SDK uses) and zones come from PHP's own database. The SQLite store needs `pdo_sqlite`, and the MySQL store `pdo_mysql`.

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

A PHP process does not stay up between runs, so missed and stuck runs are found by a check: a second crontab line (or the framework's scheduler) that declares the jobs and calls `$cw->check()` every five minutes.

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

## Testing

From this directory:

```bash
composer install
vendor/bin/phpunit
```

`tests/ConformanceTest.php` replays the cases in the repository's `conformance/` directory, generated from the TypeScript SDK. The MySQL and MariaDB tests run when `CRONWATCH_TEST_MYSQL` and `CRONWATCH_TEST_MARIADB` are `mysql://` URLs (CI starts both), for example against throwaway servers:

```bash
docker run -d --rm --name cw-mysql -e MYSQL_ROOT_PASSWORD=pw -e MYSQL_DATABASE=cw -p 33061:3306 mysql:8
docker run -d --rm --name cw-mariadb -e MARIADB_ROOT_PASSWORD=pw -e MARIADB_DATABASE=cw -p 33062:3306 mariadb:10.11
CRONWATCH_TEST_MYSQL=mysql://root:pw@127.0.0.1:33061/cw CRONWATCH_TEST_MARIADB=mysql://root:pw@127.0.0.1:33062/cw vendor/bin/phpunit
```

`tests/FinishOnceTest.php` starts PHP worker processes that finish the same runs at the same moment, on SQLite and on each server. `tests/NodeCompatTest.php` shares a SQLite file with the built SDK, and `tests/ScheduleFuzzTest.php` checks thousands of generated cron expressions against croner itself; both need Node and the SDK built first (`npm ci && npm run build` at the repository root), and skip with the reason otherwise. `npm run check:php` at the root runs the suite.

## License

MIT
